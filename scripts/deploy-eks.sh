#!/usr/bin/env bash
# deploy-eks.sh — Apply taskmanager EKS manifests to the cluster.
# Skips any Deployment whose running image already matches the manifest.
# Usage: deploy-eks.sh [--dry-run] [--namespace <ns>] [--help]
set -euo pipefail

# Explicit PATH — required for cron/CI (IRD-19 Pattern 6)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# ── Configuration (override via env vars) ─────────────────────────────────────
NAMESPACE="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${MANIFESTS_DIR:-${SCRIPT_DIR}/../eks/manifests}"
DRY_RUN=0

# ── Logging helpers (IRD-19 Pattern 4) ────────────────────────────────────────
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '[%s] [%s] %s\n'       "$(_ts)" "${PHASE:-main}" "$*"; }
err()  { printf '[%s] [%s] ERROR %s\n' "$(_ts)" "${PHASE:-main}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Dry-run wrapper ────────────────────────────────────────────────────────────
# Every state-changing command goes through run(). Read-only commands do not.
# One unwrapped command and --dry-run is a lie.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

# ── Phase helpers ──────────────────────────────────────────────────────────────
phase_start() { PHASE="$1"; log "START $2"; }
phase_ok()    { log "OK    $*"; }

# ── Usage (IRD-19 Pattern 2) ───────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--dry-run] [--namespace <ns>] [--help]

Apply taskmanager EKS manifests: StorageClass, Secrets, ConfigMaps,
StatefulSets, DB migrations, Deployments, Redis, Ingress.
Skips Deployments already at intended image; skips migrations already applied.

Required env vars:
  DB_PASS      PostgreSQL password for app_user
  JWT_SECRET   JWT signing secret for api-gateway and user-service

Optional env vars:
  NAMESPACE     Kubernetes namespace (default: default)
  MANIFESTS_DIR Path to eks/manifests/ directory (default: auto-detected)

Options:
  --dry-run         Print state-changing commands without executing them
  --namespace <ns>  Target namespace (overrides NAMESPACE env var)
  --help, -h        Show this help
EOF
  exit 2
}

# ── Argument parsing (IRD-19 Pattern 2) ───────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --namespace)
      shift
      [[ $# -ge 1 ]] || die "--namespace requires a value"
      NAMESPACE="$1"
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# ── PATH preflight (IRD-19 Pattern 6) ─────────────────────────────────────────
for tool in kubectl helm aws; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ── Preflight (IRD-22 Pattern 2) ──────────────────────────────────────────────
# Auto-discovers: cluster name, kubeconfig, manifests dir.
# Reports all missing secrets at once. Prints a summary before any state change.
# Interactive sessions get a y/N confirm; CI (non-tty stdin) proceeds automatically.
preflight() {
  phase_start "preflight" "discovering environment"

  # 1. Find EKS cluster — no need to know the name in advance.
  #    Honour EKS_CLUSTER env var for multi-cluster environments.
  local cluster="${EKS_CLUSTER:-}"
  if [[ -z "$cluster" ]]; then
    local region
    region=$(aws configure get region 2>/dev/null || echo "eu-central-1")
    log "scanning for EKS clusters in ${region}"
    cluster=$(aws eks list-clusters --query 'clusters[0]' --output text 2>/dev/null || true)
    [[ -n "$cluster" && "$cluster" != "None" ]] \
      || die "no EKS cluster found in ${region} — run: eksctl create cluster -f eks/cluster.yaml"
  fi
  log "cluster: ${cluster}"

  # 2. Auto-wire kubeconfig when kubectl cannot reach the cluster.
  if ! kubectl cluster-info &>/dev/null 2>&1; then
    local region
    region=$(aws configure get region 2>/dev/null || echo "eu-central-1")
    log "kubeconfig not connected — running update-kubeconfig"
    aws eks update-kubeconfig --region "$region" --name "$cluster"
    kubectl cluster-info &>/dev/null 2>&1 \
      || die "still cannot reach cluster after update-kubeconfig — check AWS auth"
  fi

  # 3. Auto-detect manifests dir from known candidate paths.
  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    local found=""
    local candidates=(
      "${SCRIPT_DIR}/../eks/manifests"
      "${SCRIPT_DIR}/../docs/eks/manifests"
      "${SCRIPT_DIR}/../k8s/taskmanager"
    )
    for dir in "${candidates[@]}"; do
      if [[ -d "$dir" ]]; then
        found="$(cd "$dir" && pwd)"
        break
      fi
    done
    [[ -n "$found" ]] \
      || die "cannot find manifests dir — set: export MANIFESTS_DIR=<path>"
    MANIFESTS_DIR="$found"
  fi
  log "manifests: ${MANIFESTS_DIR}"

  # 4. Check required secrets — report ALL missing ones before dying.
  local missing=()
  [[ -z "${DB_PASS:-}"    ]] && missing+=("DB_PASS")
  [[ -z "${JWT_SECRET:-}" ]] && missing+=("JWT_SECRET")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing required secrets: ${missing[*]}"
    err "set them and re-run:"
    local v
    for v in "${missing[@]}"; do err "  export ${v}='...'"; done
    exit 1
  fi

  # 5. Print summary so you see exactly what will be touched.
  local node_count
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf '\n'
  printf '  Cluster:    %s\n' "$cluster"
  printf '  Namespace:  %s\n' "$NAMESPACE"
  printf '  Manifests:  %s\n' "$MANIFESTS_DIR"
  printf '  Nodes:      %s ready\n' "$node_count"
  printf '  Dry-run:    %s\n' "$([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
  printf '\n'

  # 6. Confirm before changing anything — skipped in dry-run and in CI (non-tty).
  if [[ $DRY_RUN -eq 0 && -t 0 ]]; then
    printf 'Proceed with deploy? [y/N] '
    read -r confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] \
      || { log "aborted by user"; exit 0; }
  fi

  phase_ok "preflight complete — namespace=${NAMESPACE}"
}

# ── Phase 1: Secrets ──────────────────────────────────────────────────────────
# Pipe pattern: 'kubectl create --dry-run=client | kubectl apply' is idempotent.
# Both steps are state-changing, so apply_secret() gates on $DRY_RUN directly
# (equivalent to run() but handles the pipe correctly).
apply_secret() {
  local name="$1"
  shift
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: kubectl apply secret %s\n' "$name"
    return 0
  fi
  kubectl create secret generic "$name" "$@" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

phase_secrets() {
  phase_start "secrets" "creating/updating Secrets"

  apply_secret api-gw-secret \
    --from-literal=JWT_SECRET="${JWT_SECRET}"

  apply_secret db-task-secret \
    --from-literal=POSTGRES_PASSWORD="${DB_PASS}"

  apply_secret db-user-secret \
    --from-literal=POSTGRES_PASSWORD="${DB_PASS}"

  apply_secret task-svc-secret \
    --from-literal=DATABASE_URL="postgresql://app_user:${DB_PASS}@db-task:5432/tasks_db"

  apply_secret user-svc-secret \
    --from-literal=DATABASE_URL="postgresql://app_user:${DB_PASS}@db-user:5432/users_db" \
    --from-literal=JWT_SECRET="${JWT_SECRET}"

  phase_ok "5 Secrets applied"
}

# ── Phase 2: ConfigMaps ───────────────────────────────────────────────────────
phase_configmaps() {
  phase_start "configmaps" "applying ConfigMaps"

  local cm
  for cm in api-gw-cm task-svc-cm user-svc-cm db-task-cm db-user-cm; do
    run kubectl apply -f "${MANIFESTS_DIR}/${cm}.yaml"
  done

  phase_ok "5 ConfigMaps applied"
}

# ── Phase 3: StorageClass ─────────────────────────────────────────────────────
# gp2-retain must exist before StatefulSets are applied — DB PVCs reference it.
# Retain policy keeps the EBS volume alive even if the PVC is deleted, preventing
# accidental data loss when tearing down and re-deploying the cluster.
phase_storage() {
  phase_start "storage" "ensuring gp2-retain StorageClass exists"

  # Read-only check — not through run() because it has no side effects
  if kubectl get storageclass gp2-retain &>/dev/null; then
    log "SKIP  gp2-retain already exists"
    phase_ok "storage ready"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: kubectl apply storageclass/gp2-retain\n'
    phase_ok "storage ready (dry-run)"
    return 0
  fi

  # Heredoc piped to kubectl — equivalent to run() for a single-command apply
  kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp2
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
YAML

  log "gp2-retain StorageClass created"
  phase_ok "storage ready"
}

# ── Phase 4: StatefulSets (databases) ─────────────────────────────────────────
phase_statefulsets() {
  phase_start "statefulsets" "applying DB StatefulSets"

  run kubectl apply -f "${MANIFESTS_DIR}/db-task-statefulset.yaml"
  run kubectl apply -f "${MANIFESTS_DIR}/db-user-statefulset.yaml"

  phase_ok "2 StatefulSets applied"
}

# ── Phase 5: DB Migrations ────────────────────────────────────────────────────
# Runs ONLY when tables are absent — safe to call on every deploy (idempotent).
# Uses -i (stdin) to pipe the SQL file rather than -c "$(cat)" to avoid quoting
# issues with dollar-signs and special characters in the SQL.
phase_migrate() {
  phase_start "migrate" "running DB schema migrations"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "SKIP  migrations in dry-run mode"
    phase_ok "migrations skipped (dry-run)"
    return 0
  fi

  local REPO_ROOT
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

  # Wait for both DB pods to accept connections before running psql
  for pod in db-user-0 db-task-0; do
    log "waiting for ${pod} Ready (timeout 120s)"
    kubectl wait pod "${pod}" \
      --namespace="${NAMESPACE}" \
      --for=condition=Ready \
      --timeout=120s \
      || die "${pod} not Ready — check: kubectl describe pod ${pod} -n ${NAMESPACE}"
  done

  # ── users DB ──────────────────────────────────────────────────────────────
  local users_exists
  users_exists=$(kubectl exec db-user-0 --namespace="${NAMESPACE}" -- \
    psql -U app_user -d users_db -tAc \
    "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='users');" \
    2>/dev/null || echo "f")

  if [[ "${users_exists//[[:space:]]/}" == "t" ]]; then
    log "SKIP  users schema already applied"
  else
    local users_sql="${REPO_ROOT}/user-service/db/migrations/001_create_users.sql"
    [[ -f "$users_sql" ]] || die "migration not found: ${users_sql}"
    kubectl exec -i db-user-0 --namespace="${NAMESPACE}" -- \
      psql -U app_user -d users_db < "${users_sql}"
    log "users schema applied"
  fi

  # ── tasks DB ──────────────────────────────────────────────────────────────
  local tasks_exists
  tasks_exists=$(kubectl exec db-task-0 --namespace="${NAMESPACE}" -- \
    psql -U app_user -d tasks_db -tAc \
    "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='tasks');" \
    2>/dev/null || echo "f")

  if [[ "${tasks_exists//[[:space:]]/}" == "t" ]]; then
    log "SKIP  tasks schema already applied"
  else
    local tasks_sql="${REPO_ROOT}/task-service/db/migrations/001_create_tables.sql"
    [[ -f "$tasks_sql" ]] || die "migration not found: ${tasks_sql}"
    kubectl exec -i db-task-0 --namespace="${NAMESPACE}" -- \
      psql -U app_user -d tasks_db < "${tasks_sql}"
    log "tasks schema applied"
  fi

  phase_ok "migrations complete"
}

# ── Phase 6: Deployments (idempotency check per Deployment) ──────────────────
# Reads intended image from the manifest, compares with the running image in the
# cluster. Skips kubectl apply if they already match. Treats "not found" (first
# deploy) as "not deployed → apply".
deploy_one() {
  local name="$1"
  local manifest="$2"

  # Extract intended image from first 'image:' line — read-only, no run()
  local intended
  intended=$(awk '/image:/{print $2; exit}' "${manifest}")
  [[ -n "$intended" ]] || die "no 'image:' line found in ${manifest}"

  # Query current running image; empty string if Deployment does not exist yet — read-only
  local running
  running=$(kubectl get deployment "${name}" \
    --namespace="${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

  if [[ -n "$running" && "$running" == "$intended" ]]; then
    log "SKIP  ${name} — already at ${intended}"
    return 0
  fi

  log "applying ${name} (running: ${running:-<none>} → intended: ${intended})"
  run kubectl apply -f "${manifest}"
}

phase_deployments() {
  phase_start "deployments" "applying app Deployments (idempotency check per service)"

  deploy_one "task-service"     "${MANIFESTS_DIR}/task-svc-deployment.yaml"
  deploy_one "user-service"     "${MANIFESTS_DIR}/user-svc-deployment.yaml"
  deploy_one "api-gateway"      "${MANIFESTS_DIR}/api-gw-deployment.yaml"
  deploy_one "frontend-service" "${MANIFESTS_DIR}/frontend-deployment.yaml"

  phase_ok "4 Deployments processed"
}

# ── Phase 5: Redis (Helm) ─────────────────────────────────────────────────────
phase_redis() {
  phase_start "redis" "installing/upgrading Redis via Helm"

  # repo add is idempotent; suppress "already exists" warning with 2>/dev/null
  run helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  run helm repo update
  run helm upgrade --install my-redis bitnami/redis \
    -f "${MANIFESTS_DIR}/my-redis-values.yaml" \
    --namespace="${NAMESPACE}" \
    --wait --timeout=5m

  phase_ok "Redis ready"
}

# ── Phase 6: Rollout status ───────────────────────────────────────────────────
# Uses kubectl rollout status (not curl) — EKS services have no external port
# without a port-forward; rollout status is the cluster-native observable.
# Skipped in dry-run because nothing was deployed.
phase_rollout() {
  phase_start "rollout" "waiting for Deployments to become Ready (timeout 120s each)"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "SKIP  rollout check in dry-run mode (nothing was deployed)"
    return 0
  fi

  local name
  for name in task-service user-service api-gateway frontend-service; do
    kubectl rollout status "deployment/${name}" \
      --namespace="${NAMESPACE}" \
      --timeout=120s \
      || die "${name} did not become Ready — check: kubectl describe pod -n ${NAMESPACE} -l app=${name}"
    phase_ok "${name} ready"
  done
}

# ── Phase 9: Ingress ──────────────────────────────────────────────────────────
# Applied last — all backend Services must exist before the ingress controller
# can resolve them. Waits for the ELB hostname so the operator gets a clickable URL.
phase_ingress() {
  phase_start "ingress" "applying Ingress resources"

  run kubectl apply -f "${MANIFESTS_DIR}/ingress.yaml"

  if [[ $DRY_RUN -eq 1 ]]; then
    phase_ok "ingress applied (dry-run)"
    return 0
  fi

  # Poll for ELB hostname — AWS takes 30-90s to provision the NLB
  log "waiting for LoadBalancer hostname (timeout 120s)"
  local elapsed=0 elb=""
  while [[ -z "$elb" && $elapsed -lt 120 ]]; do
    elb=$(kubectl get svc ingress-nginx-controller \
      -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -z "$elb" ]] && { sleep 5; elapsed=$(( elapsed + 5 )); }
  done

  if [[ -n "$elb" ]]; then
    printf '\n'
    printf '  Frontend : http://%s/\n'     "$elb"
    printf '  API      : http://%s/api/\n' "$elb"
    printf '\n'
  else
    log "WARNING: ELB hostname not yet assigned — check: kubectl get svc -n ingress-nginx"
  fi

  phase_ok "ingress applied"
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN mode — no state will be changed"

  preflight
  phase_secrets
  phase_configmaps
  phase_storage      # StorageClass must exist before StatefulSets request PVCs
  phase_statefulsets
  phase_migrate      # Tables must exist before app Deployments start serving traffic
  phase_deployments
  phase_redis
  phase_rollout
  phase_ingress      # Applied last — backends must exist before ingress resolves them

  PHASE="main"
  log "OK    deploy complete — namespace=${NAMESPACE}"
  kubectl get pods --namespace="${NAMESPACE}"
}

main "$@"
