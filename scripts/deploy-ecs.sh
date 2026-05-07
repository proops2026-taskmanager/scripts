#!/usr/bin/env bash
# deploy-ecs.sh — ECS Fargate full migration arc toolkit
# IRD-25: preflight → cluster → log-groups → task-defs → alb → services → autoscale → wait-stable → verify
# Flags: --dry-run  --scale <svc>=<N>  --update  --teardown
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# ── Constants ──────────────────────────────────────────────────────────────────
readonly CLUSTER_NAME="${ECS_CLUSTER:-taskmanager-dev}"
readonly AWS_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
readonly IMAGE_TAG="${IMAGE_TAG:-v2}"
readonly NAMESPACE="taskmanager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly TASK_DEFS_DIR="${REPO_ROOT}/ecs/task-defs"

# Deploy order: infra first, then apps that depend on them
readonly ALL_SERVICES=(redis postgres-task postgres-user user-service task-service api-gateway frontend-service)
readonly AUTOSCALE_SERVICES=(api-gateway task-service)

# Discovered at runtime by discover_infra()
VPC_ID=""
PUBLIC_SUBNET_IDS=""
ECS_SG_ID=""
ALB_SG_ID=""
ALB_ARN=""
ALB_DNS=""
FRONTEND_TG_ARN=""
APIGW_TG_ARN=""

# ── Logging helpers ────────────────────────────────────────────────────────────
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '[%s][%-12s] %s\n'       "$(_ts)" "${PHASE:-main}" "$*"; }
err()  { printf '[%s][%-12s] ERROR %s\n' "$(_ts)" "${PHASE:-main}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Dry-run wrapper ────────────────────────────────────────────────────────────
DRY_RUN=0
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*" >&2   # stderr so > /dev/null on the call site never hides it
  else
    "$@"
  fi
}

# ── Phase helpers ──────────────────────────────────────────────────────────────
PHASE="main"
phase_start() { PHASE="$1"; log "START $2"; }
phase_ok()    { log "OK    $*"; }

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  printf 'Usage: %s [OPTIONS]\n\n' "$(basename "$0")"
  printf 'Options:\n'
  printf '  --dry-run          Show all phases without calling AWS\n'
  printf '  --scale <svc>=<N>  Set desired count for one service\n'
  printf '  --update           Re-register task defs + rolling update all services\n'
  printf '  --teardown         Delete all ECS resources and verify zero orphans\n'
  printf '  --help             Show this message\n' >&2
  exit 2
}

# ── Argument parsing ───────────────────────────────────────────────────────────
SCALE_SVC=""; SCALE_N=0; DO_UPDATE=0; DO_TEARDOWN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --update)   DO_UPDATE=1; shift ;;
    --teardown) DO_TEARDOWN=1; shift ;;
    --scale)
      [[ "${2:-}" =~ ^([a-z-]+)=([0-9]+)$ ]] \
        || die "--scale requires format <service-name>=<count>, e.g. --scale api-gateway=3"
      SCALE_SVC="${BASH_REMATCH[1]}"
      SCALE_N="${BASH_REMATCH[2]}"
      shift 2 ;;
    --help|-h) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: preflight
# ══════════════════════════════════════════════════════════════════════════════
preflight() {
  phase_start "preflight" "checking tools, secrets, and AWS identity"

  # Tool check (IRD-19 Pattern 6)
  local missing_tools=()
  for cmd in aws jq curl; do
    command -v "$cmd" >/dev/null || missing_tools+=("$cmd")
  done
  [[ ${#missing_tools[@]} -eq 0 ]] || die "missing required tools: ${missing_tools[*]}"

  # AWS identity
  local account
  account=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) \
    || die "AWS credentials not active — run: source ./scripts/aws-session-init.sh"
  log "  account=$account region=$AWS_REGION"

  # Required secrets — report ALL missing at once
  local missing_vars=()
  [[ -n "${DB_PASS:-}"    ]] || missing_vars+=("export DB_PASS='<your-db-password>'")
  [[ -n "${JWT_SECRET:-}" ]] || missing_vars+=("export JWT_SECRET='$(openssl rand -base64 32)'")
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    err "missing required environment variables — set all before re-running:"
    for v in "${missing_vars[@]}"; do err "  $v"; done
    exit 1
  fi

  # Task defs directory
  [[ -d "$TASK_DEFS_DIR" ]] \
    || die "task definitions not found at $TASK_DEFS_DIR — run from repo root"

  phase_ok "tools=ok identity=ok secrets=ok"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: discover_infra (read-only — not wrapped in run())
# ══════════════════════════════════════════════════════════════════════════════
discover_infra() {
  phase_start "discover" "finding VPC, subnets, and security groups"

  # VPC — tagged Project=taskmanager
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=taskmanager" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v None || true)
  [[ -n "$VPC_ID" ]] \
    || die "no VPC tagged Project=taskmanager found — create VPC first or tag existing one"

  # Public subnets (comma-separated for CLI)
  PUBLIC_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
    --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
  [[ -n "$PUBLIC_SUBNET_IDS" ]] \
    || die "no public subnets found in VPC $VPC_ID"

  log "  vpc=$VPC_ID"
  log "  public_subnets=$PUBLIC_SUBNET_IDS"
  phase_ok "infra discovered"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: cluster
# ══════════════════════════════════════════════════════════════════════════════
ensure_cluster() {
  phase_start "cluster" "ensuring ECS cluster $CLUSTER_NAME"

  local status
  status=$(aws ecs describe-clusters \
    --clusters "$CLUSTER_NAME" \
    --query 'clusters[0].status' --output text 2>/dev/null | grep -v None || true)

  if [[ "$status" == "ACTIVE" ]]; then
    phase_ok "cluster already ACTIVE"
    return
  fi

  run aws ecs create-cluster \
    --cluster-name "$CLUSTER_NAME" \
    --capacity-providers FARGATE_SPOT FARGATE \
    --default-capacity-provider-strategy \
      capacityProvider=FARGATE_SPOT,weight=1 \
      capacityProvider=FARGATE,weight=0 \
    --settings name=containerInsights,value=enabled \
    --tags key=Project,value=taskmanager key=ManagedBy,value=deploy-ecs.sh \
    --output text > /dev/null

  phase_ok "cluster $CLUSTER_NAME created"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: security-groups
# ══════════════════════════════════════════════════════════════════════════════
ensure_security_groups() {
  phase_start "sg" "ensuring ALB and ECS security groups"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] would create taskmanager-alb-sg (inbound 80/tcp) and taskmanager-ecs-sg"
    ALB_SG_ID="<alb-sg-pending>"; ECS_SG_ID="<ecs-sg-pending>"
    phase_ok "[dry-run] sg phase complete"; return
  fi

  # ALB SG — allow inbound HTTP from internet
  ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=taskmanager-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v None || true)

  if [[ -z "$ALB_SG_ID" ]]; then
    ALB_SG_ID=$(run aws ec2 create-security-group \
      --group-name taskmanager-alb-sg \
      --description "taskmanager ALB — allow inbound HTTP" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=taskmanager-alb-sg},{Key=Project,Value=taskmanager}]" \
      --query 'GroupId' --output text)
    run aws ec2 authorize-security-group-ingress \
      --group-id "$ALB_SG_ID" \
      --protocol tcp --port 80 --cidr 0.0.0.0/0
    log "  created ALB SG: $ALB_SG_ID"
  else
    log "  reusing ALB SG: $ALB_SG_ID"
  fi

  # ECS SG — allow inbound from ALB SG only
  ECS_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=taskmanager-ecs-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v None || true)

  if [[ -z "$ECS_SG_ID" ]]; then
    ECS_SG_ID=$(run aws ec2 create-security-group \
      --group-name taskmanager-ecs-sg \
      --description "taskmanager ECS tasks — allow inbound from ALB and Service Connect" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=taskmanager-ecs-sg},{Key=Project,Value=taskmanager}]" \
      --query 'GroupId' --output text)
    # Allow from ALB on app ports
    run aws ec2 authorize-security-group-ingress \
      --group-id "$ECS_SG_ID" \
      --protocol tcp --port 3000 --source-group "$ALB_SG_ID"
    run aws ec2 authorize-security-group-ingress \
      --group-id "$ECS_SG_ID" \
      --protocol tcp --port 3001 --source-group "$ALB_SG_ID"
    # Allow all traffic within ECS SG (Service Connect inter-service calls)
    run aws ec2 authorize-security-group-ingress \
      --group-id "$ECS_SG_ID" \
      --protocol -1 --source-group "$ECS_SG_ID"
    log "  created ECS SG: $ECS_SG_ID"
  else
    log "  reusing ECS SG: $ECS_SG_ID"
  fi

  phase_ok "alb-sg=$ALB_SG_ID ecs-sg=$ECS_SG_ID"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: log-groups
# ══════════════════════════════════════════════════════════════════════════════
create_log_groups() {
  phase_start "log-groups" "creating CloudWatch log groups"
  for svc in "${ALL_SERVICES[@]}"; do
    local lg="/ecs/taskmanager/${svc}"
    if aws logs describe-log-groups \
        --log-group-name-prefix "$lg" \
        --query 'length(logGroups)' --output text 2>/dev/null | grep -q "^0$"; then
      run aws logs create-log-group --log-group-name "$lg" \
        --tags Project=taskmanager
      log "  created $lg"
    else
      log "  exists  $lg"
    fi
  done
  phase_ok "7 log groups ready"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: task-defs
# ══════════════════════════════════════════════════════════════════════════════
register_task_defs() {
  phase_start "task-defs" "registering task definitions"
  for svc in "${ALL_SERVICES[@]}"; do
    local json_file="${TASK_DEFS_DIR}/${svc}.json"
    [[ -f "$json_file" ]] || die "missing task def: $json_file"
    local rev
    rev=$(run aws ecs register-task-definition \
      --cli-input-json "file://${json_file}" \
      --query 'taskDefinition.revision' --output text)
    log "  taskmanager-${svc}:${rev}"
  done
  phase_ok "7 task definitions registered"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: alb
# ══════════════════════════════════════════════════════════════════════════════
ensure_alb() {
  phase_start "alb" "ensuring Application Load Balancer"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] would create taskmanager-alb, frontend TG (3000), api-gateway TG (3001), listener port 80"
    ALB_DNS="<alb-dns-pending>"; FRONTEND_TG_ARN="<frontend-tg-pending>"; APIGW_TG_ARN="<apigw-tg-pending>"
    phase_ok "[dry-run] alb phase complete — http://<alb-dns-pending>"; return
  fi

  # Check existing ALB
  ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names taskmanager-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | grep -v None || true)

  if [[ -z "$ALB_ARN" ]]; then
    # Convert comma-separated subnet IDs to space-separated for CLI
    local -a subnet_arr
    IFS=',' read -ra subnet_arr <<< "$PUBLIC_SUBNET_IDS"
    ALB_ARN=$(run aws elbv2 create-load-balancer \
      --name taskmanager-alb \
      --subnets "${subnet_arr[@]}" \
      --security-groups "$ALB_SG_ID" \
      --scheme internet-facing \
      --type application \
      --ip-address-type ipv4 \
      --tags Key=Project,Value=taskmanager \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)
    log "  created ALB: $ALB_ARN"
  else
    log "  reusing ALB: $ALB_ARN"
  fi

  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)
  log "  ALB DNS: $ALB_DNS"

  # Frontend target group
  FRONTEND_TG_ARN=$(aws elbv2 describe-target-groups \
    --names taskmanager-frontend-service-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | grep -v None || true)
  if [[ -z "$FRONTEND_TG_ARN" ]]; then
    FRONTEND_TG_ARN=$(run aws elbv2 create-target-group \
      --name taskmanager-frontend-service-tg \
      --protocol HTTP --port 3000 \
      --vpc-id "$VPC_ID" \
      --target-type ip \
      --health-check-path /health \
      --health-check-interval-seconds 30 \
      --healthy-threshold-count 2 \
      --tags Key=Project,Value=taskmanager \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
    log "  created frontend TG: $FRONTEND_TG_ARN"
  fi

  # API Gateway target group
  APIGW_TG_ARN=$(aws elbv2 describe-target-groups \
    --names taskmanager-api-gateway-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | grep -v None || true)
  if [[ -z "$APIGW_TG_ARN" ]]; then
    APIGW_TG_ARN=$(run aws elbv2 create-target-group \
      --name taskmanager-api-gateway-tg \
      --protocol HTTP --port 3001 \
      --vpc-id "$VPC_ID" \
      --target-type ip \
      --health-check-path /health \
      --health-check-interval-seconds 30 \
      --healthy-threshold-count 2 \
      --tags Key=Project,Value=taskmanager \
      --query 'TargetGroups[0].TargetGroupArn' --output text)
    log "  created api-gateway TG: $APIGW_TG_ARN"
  fi

  # Listener — default → frontend; /api/* → api-gateway
  local listener_arn
  # shellcheck disable=SC2016
  listener_arn=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null | grep -v None || true)
  if [[ -z "$listener_arn" ]]; then
    listener_arn=$(run aws elbv2 create-listener \
      --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=${FRONTEND_TG_ARN}" \
      --query 'Listeners[0].ListenerArn' --output text)
    run aws elbv2 create-rule \
      --listener-arn "$listener_arn" \
      --priority 10 \
      --conditions "Field=path-pattern,Values='/api/*'" \
      --actions "Type=forward,TargetGroupArn=${APIGW_TG_ARN}"
    log "  created listener + /api/* rule"
  else
    log "  listener already exists"
  fi

  phase_ok "ALB ready — http://${ALB_DNS}"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: services
# ══════════════════════════════════════════════════════════════════════════════
deploy_services() {
  phase_start "services" "creating or updating ECS services"

  if [[ $DRY_RUN -eq 1 ]]; then
    for svc in "${ALL_SERVICES[@]}"; do
      log "  [dry-run] would create/update service: $svc (taskmanager-${svc}:latest-revision)"
    done
    phase_ok "[dry-run] 7 services phase complete"; return
  fi

  local network_config
  network_config="awsvpcConfiguration={subnets=[${PUBLIC_SUBNET_IDS}],securityGroups=[${ECS_SG_ID}],assignPublicIp=ENABLED}"

  for svc in "${ALL_SERVICES[@]}"; do
    local family="taskmanager-${svc}"
    local existing
    # shellcheck disable=SC2016
    existing=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" --services "$svc" \
      --query 'services[?status==`ACTIVE`].serviceName' \
      --output text 2>/dev/null | grep -v None || true)

    if [[ -z "$existing" ]]; then
      # Build create-service args
      local create_args=(
        --cluster "$CLUSTER_NAME"
        --service-name "$svc"
        --task-definition "$family"
        --desired-count 1
        --capacity-provider-strategy
          "capacityProvider=FARGATE_SPOT,weight=1"
          "capacityProvider=FARGATE,weight=0"
        --network-configuration "$network_config"
        --service-connect-configuration "enabled=true,namespace=${NAMESPACE}"
        --tags "key=Project,value=taskmanager"
      )

      # Attach load balancer for ALB-fronted services
      if [[ "$svc" == "frontend-service" ]]; then
        create_args+=(--load-balancers "targetGroupArn=${FRONTEND_TG_ARN},containerName=frontend-service,containerPort=3000")
        create_args+=(--health-check-grace-period-seconds 60)
      elif [[ "$svc" == "api-gateway" ]]; then
        create_args+=(--load-balancers "targetGroupArn=${APIGW_TG_ARN},containerName=api-gateway,containerPort=3001")
        create_args+=(--health-check-grace-period-seconds 60)
      fi

      run aws ecs create-service "${create_args[@]}" --output text > /dev/null
      log "  created service: $svc"
    else
      run aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$svc" \
        --task-definition "$family" \
        --output text > /dev/null
      log "  updated service: $svc"
    fi
  done

  phase_ok "7 services deployed"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: autoscale
# ══════════════════════════════════════════════════════════════════════════════
configure_autoscale() {
  phase_start "autoscale" "configuring Application Auto Scaling (cpu target 60%)"

  for svc in "${AUTOSCALE_SERVICES[@]}"; do
    local resource_id="service/${CLUSTER_NAME}/${svc}"

    run aws application-autoscaling register-scalable-target \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$resource_id" \
      --min-capacity 1 --max-capacity 4

    run aws application-autoscaling put-scaling-policy \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$resource_id" \
      --policy-name "${svc}-cpu-target" \
      --policy-type TargetTrackingScaling \
      --target-tracking-scaling-policy-configuration '{
        "TargetValue": 60.0,
        "PredefinedMetricSpecification": {
          "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
        },
        "ScaleInCooldown": 300,
        "ScaleOutCooldown": 60
      }' --output text > /dev/null

    log "  $svc → cpu-target=60% min=1 max=4"
  done

  phase_ok "auto scaling configured for: ${AUTOSCALE_SERVICES[*]}"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: wait-stable
# ══════════════════════════════════════════════════════════════════════════════
wait_stable() {
  phase_start "wait-stable" "polling until all 7 services RUNNING (timeout=5min)"
  local deadline=$(( $(date +%s) + 300 ))

  while true; do
    local all_stable=1
    for svc in "${ALL_SERVICES[@]}"; do
      local running desired
      running=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" --services "$svc" \
        --query 'services[0].runningCount' --output text 2>/dev/null || echo 0)
      desired=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" --services "$svc" \
        --query 'services[0].desiredCount' --output text 2>/dev/null || echo 1)
      if [[ "$running" != "$desired" ]]; then
        log "  $svc: ${running}/${desired} running"
        all_stable=0
      fi
    done
    if [[ $all_stable -eq 1 ]]; then
      phase_ok "all services stable"
      return
    fi
    if (( $(date +%s) >= deadline )); then
      die "timeout: not all services stable after 5 min — check ECS console for stopped task reasons"
    fi
    sleep 10
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE: verify
# ══════════════════════════════════════════════════════════════════════════════
verify() {
  phase_start "verify" "health-checking ALB endpoints"

  local endpoints=(
    "http://${ALB_DNS}/health|frontend"
    "http://${ALB_DNS}/api/health|api-gateway"
  )

  for entry in "${endpoints[@]}"; do
    local url="${entry%%|*}"
    local label="${entry##*|}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" || printf '000')
    if [[ "$code" == "200" ]]; then
      log "  $label → HTTP $code ✓"
    else
      die "$label health check failed — got HTTP $code from $url"
    fi
  done

  phase_ok "ALB verified — http://${ALB_DNS}"
  printf '\n=== DEPLOY COMPLETE ===\n'
  printf 'Frontend:   http://%s\n' "$ALB_DNS"
  printf 'API:        http://%s/api\n' "$ALB_DNS"
}

# ══════════════════════════════════════════════════════════════════════════════
# FLAG: --scale
# ══════════════════════════════════════════════════════════════════════════════
scale_service() {
  local svc="$1" count="$2"
  phase_start "scale" "setting $svc desired count → $count"

  # Validate service name
  local valid=0
  for s in "${ALL_SERVICES[@]}"; do
    [[ "$s" == "$svc" ]] && valid=1 && break
  done
  [[ $valid -eq 1 ]] || die "unknown service '$svc' — valid: ${ALL_SERVICES[*]}"

  run aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$svc" \
    --desired-count "$count" \
    --output text > /dev/null

  phase_ok "$svc desired count set to $count"
  log "  verify: aws ecs describe-services --cluster $CLUSTER_NAME --services $svc --query 'services[0].{running:runningCount,desired:desiredCount}'"
}

# ══════════════════════════════════════════════════════════════════════════════
# FLAG: --update (rolling update)
# ══════════════════════════════════════════════════════════════════════════════
rolling_update() {
  phase_start "update" "re-registering task defs + rolling update all services"

  for svc in "${ALL_SERVICES[@]}"; do
    local json_file="${TASK_DEFS_DIR}/${svc}.json"
    [[ -f "$json_file" ]] || die "missing task def: $json_file"

    local new_arn
    new_arn=$(run aws ecs register-task-definition \
      --cli-input-json "file://${json_file}" \
      --query 'taskDefinition.taskDefinitionArn' --output text)

    run aws ecs update-service \
      --cluster "$CLUSTER_NAME" \
      --service "$svc" \
      --task-definition "$new_arn" \
      --output text > /dev/null

    log "  $svc → $(basename "$new_arn")"
  done

  log "  waiting for rolling update to complete..."
  # Re-discover ALB DNS for verify step
  ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names taskmanager-alb \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
  wait_stable
  if [[ -n "$ALB_DNS" ]]; then
    verify
  else
    phase_ok "update complete (no ALB found — skipping verify)"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# FLAG: --teardown
# ══════════════════════════════════════════════════════════════════════════════
teardown() {
  phase_start "teardown" "deleting all taskmanager ECS resources"

  log "  step 1/5 — deregistering auto scaling policies"
  for svc in "${AUTOSCALE_SERVICES[@]}"; do
    local resource_id="service/${CLUSTER_NAME}/${svc}"
    run aws application-autoscaling delete-scaling-policy \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$resource_id" \
      --policy-name "${svc}-cpu-target" 2>/dev/null || true
    run aws application-autoscaling deregister-scalable-target \
      --service-namespace ecs \
      --scalable-dimension ecs:service:DesiredCount \
      --resource-id "$resource_id" 2>/dev/null || true
    log "    deregistered autoscaling: $svc"
  done

  log "  step 2/5 — draining and deleting ECS services"
  for svc in "${ALL_SERVICES[@]}"; do
    local status
    status=$(aws ecs describe-services \
      --cluster "$CLUSTER_NAME" --services "$svc" \
      --query 'services[0].status' --output text 2>/dev/null | grep -v None || true)
    if [[ "$status" == "ACTIVE" ]]; then
      run aws ecs update-service \
        --cluster "$CLUSTER_NAME" --service "$svc" \
        --desired-count 0 --output text > /dev/null
      run aws ecs delete-service \
        --cluster "$CLUSTER_NAME" --service "$svc" \
        --force --output text > /dev/null
      log "    deleted service: $svc"
    else
      log "    not found: $svc"
    fi
  done

  log "  step 3/5 — deleting ALB, listeners, and target groups"
  local alb_arn_td
  alb_arn_td=$(aws elbv2 describe-load-balancers \
    --names taskmanager-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | grep -v None || true)
  if [[ -n "$alb_arn_td" ]]; then
    # Delete listeners first (target groups can't be deleted while in use)
    while IFS= read -r arn; do
      [[ -n "$arn" ]] && run aws elbv2 delete-listener --listener-arn "$arn"
    done < <(aws elbv2 describe-listeners \
      --load-balancer-arn "$alb_arn_td" \
      --query 'Listeners[*].ListenerArn' --output text | tr '\t' '\n')
    run aws elbv2 delete-load-balancer --load-balancer-arn "$alb_arn_td"
    log "    deleted ALB: taskmanager-alb"
    log "    waiting for ALB deletion..."
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$alb_arn_td" 2>/dev/null || true
  fi
  for tg_name in taskmanager-frontend-service-tg taskmanager-api-gateway-tg; do
    local tg_arn
    tg_arn=$(aws elbv2 describe-target-groups \
      --names "$tg_name" \
      --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | grep -v None || true)
    [[ -n "$tg_arn" ]] && run aws elbv2 delete-target-group --target-group-arn "$tg_arn" \
      && log "    deleted TG: $tg_name"
  done

  log "  step 4/5 — deleting CloudWatch log groups"
  for svc in "${ALL_SERVICES[@]}"; do
    local lg="/ecs/taskmanager/${svc}"
    if aws logs describe-log-groups \
        --log-group-name-prefix "$lg" \
        --query 'length(logGroups)' --output text 2>/dev/null | grep -qv "^0$"; then
      run aws logs delete-log-group --log-group-name "$lg"
      log "    deleted: $lg"
    fi
  done

  log "  step 5/5 — verifying zero orphan resources"
  verify_teardown

  phase_ok "teardown complete"
}

verify_teardown() {
  local errors=0

  local svc_count
  svc_count=$(aws ecs list-services \
    --cluster "$CLUSTER_NAME" \
    --query 'length(serviceArns)' --output text 2>/dev/null || echo 0)
  [[ "$svc_count" -eq 0 ]] \
    || { err "$svc_count ECS services still running in $CLUSTER_NAME"; (( errors++ )) || true; }

  local alb_count
  alb_count=$(aws elbv2 describe-load-balancers \
    --query "length(LoadBalancers[?contains(LoadBalancerName,'taskmanager')])" \
    --output text 2>/dev/null || echo 0)
  [[ "$alb_count" -eq 0 ]] \
    || { err "$alb_count ALBs still exist"; (( errors++ )) || true; }

  local lg_count
  lg_count=$(aws logs describe-log-groups \
    --log-group-name-prefix /ecs/taskmanager \
    --query 'length(logGroups)' --output text 2>/dev/null || echo 0)
  [[ "$lg_count" -eq 0 ]] \
    || { err "$lg_count CloudWatch log groups remain"; (( errors++ )) || true; }

  [[ $errors -eq 0 ]] || die "teardown incomplete — $errors resource type(s) still exist"
  log "  zero orphan resources — billing stopped"
}

# ══════════════════════════════════════════════════════════════════════════════
# Full deploy pipeline
# ══════════════════════════════════════════════════════════════════════════════
deploy() {
  log "=== ECS Fargate deploy — cluster=${CLUSTER_NAME} tag=${IMAGE_TAG} dry-run=${DRY_RUN} ==="
  discover_infra
  ensure_cluster
  ensure_security_groups
  create_log_groups
  register_task_defs
  ensure_alb
  deploy_services
  configure_autoscale
  wait_stable
  verify
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry point
# ══════════════════════════════════════════════════════════════════════════════
main() {
  preflight
  if [[ $DO_TEARDOWN -eq 1 ]]; then
    discover_infra || true   # best-effort for teardown
    teardown
    return
  fi
  if [[ -n "$SCALE_SVC" ]]; then
    scale_service "$SCALE_SVC" "$SCALE_N"
    return
  fi
  if [[ $DO_UPDATE -eq 1 ]]; then
    rolling_update
    return
  fi
  deploy
}
main "$@"
