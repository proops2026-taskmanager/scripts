#!/usr/bin/env bash
# deploy-v2.sh — Apply taskmanager EKS manifests to the cluster.
# Skips any Deployment whose running image already matches the manifest.
# Usage: deploy-v2.sh [--dry-run] [--namespace <ns>] [--help]
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

Apply taskmanager EKS manifests: Secrets, ConfigMaps, StatefulSets,
Deployments, Redis Helm chart. Skips Deployments already at intended image.

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
for tool in kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ── Preflight (IRD-22 Pattern 2) ──────────────────────────────────────────────
preflight() {
  phase_start "preflight" "checking prerequisites"

  # Secrets must be set in the caller's environment — never hardcoded
  [[ -n "${DB_PASS:-}" ]]    || die "DB_PASS env var is required but not set"
  [[ -n "${JWT_SECRET:-}" ]] || die "JWT_SECRET env var is required but not set"

  # Manifests directory must be readable
  [[ -d "$MANIFESTS_DIR" ]] || die "MANIFESTS_DIR not found: $MANIFESTS_DIR"

  # Cluster reachability — read-only, NOT wrapped in run()
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach cluster — check kubeconfig context and AWS auth"

  phase_ok "cluster reachable, namespace=${NAMESPACE}, manifests=${MANIFESTS_DIR}"
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

# ── Phase 3: StatefulSets (databases) ─────────────────────────────────────────
phase_statefulsets() {
  phase_start "statefulsets" "applying DB StatefulSets"

  run kubectl apply -f "${MANIFESTS_DIR}/db-task-statefulset.yaml"
  run kubectl apply -f "${MANIFESTS_DIR}/db-user-statefulset.yaml"

  phase_ok "2 StatefulSets applied"
}

# ── Phase 4: Deployments (idempotency check per Deployment) ──────────────────
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

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN mode — no state will be changed"

  preflight
  phase_secrets
  phase_configmaps
  phase_statefulsets
  phase_deployments
  phase_redis
  phase_rollout

  PHASE="main"
  log "OK    deploy complete — namespace=${NAMESPACE}"
  kubectl get pods --namespace="${NAMESPACE}"
}

main "$@"
