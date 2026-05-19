# shellcheck shell=bash
# eks-common.sh — Logging, dry-run wrapper, phase helpers, preflight.
# Sourced by deploy-eks.sh. Requires NAMESPACE, MANIFESTS_DIR, DRY_RUN, SCRIPT_DIR
# to already be set by the caller before sourcing.

# ── Logging (IRD-19 Pattern 4) ────────────────────────────────────────────────
_ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '[%s] [%s] %s\n'       "$(_ts)" "${PHASE:-main}" "$*"; }
err()  { printf '[%s] [%s] ERROR %s\n' "$(_ts)" "${PHASE:-main}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
# Every state-changing command goes through run(). Read-only commands do not.
# One unwrapped command and --dry-run is a lie.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

# ── Phase helpers ─────────────────────────────────────────────────────────────
phase_start() { PHASE="$1"; log "START $2"; }
phase_ok()    { log "OK    $*"; }

# ── Usage (IRD-19 Pattern 2) ──────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
Usage: deploy-eks.sh [--dry-run] [--namespace <ns>] [--help]

Apply taskmanager EKS manifests: StorageClass, Secrets, ConfigMaps,
StatefulSets, DB migrations, Deployments, Redis, Ingress, HPA.
Skips Deployments already at intended image; skips migrations already applied.

Required env vars:
  DB_PASS      PostgreSQL password for app_user
  JWT_SECRET   JWT signing secret for api-gateway and user-service

Optional env vars:
  NAMESPACE     Kubernetes namespace (default: default)
  MANIFESTS_DIR Path to eks/manifests/ directory (default: auto-detected)
  EKS_CLUSTER   Cluster name (default: auto-detected from AWS)

Options:
  --dry-run         Print state-changing commands without executing them
  --namespace <ns>  Target namespace (overrides NAMESPACE env var)
  --help, -h        Show this help
EOF
  exit 2
}

# ── Preflight ─────────────────────────────────────────────────────────────────
# Auto-discovers cluster + kubeconfig + manifests dir.
# Reports all missing secrets at once. Prints summary before any state change.
# Interactive sessions get a y/N confirm; CI (non-tty stdin) proceeds automatically.
preflight() {
  phase_start "preflight" "discovering environment"

  # 1. Find EKS cluster — honour EKS_CLUSTER env var for multi-cluster envs
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

  # 2. Auto-wire kubeconfig when kubectl cannot reach the cluster
  if ! kubectl cluster-info &>/dev/null 2>&1; then
    local region
    region=$(aws configure get region 2>/dev/null || echo "eu-central-1")
    log "kubeconfig not connected — running update-kubeconfig"
    aws eks update-kubeconfig --region "$region" --name "$cluster"
    kubectl cluster-info &>/dev/null 2>&1 \
      || die "still cannot reach cluster after update-kubeconfig — check AWS auth"
  fi

  # 3. Auto-detect manifests dir from known candidate paths
  if [[ ! -d "$MANIFESTS_DIR" ]]; then
    local found="" dir
    local candidates=(
      "${SCRIPT_DIR}/../eks/manifests"
      "${SCRIPT_DIR}/../docs/eks/manifests"
      "${SCRIPT_DIR}/../k8s/taskmanager"
    )
    for dir in "${candidates[@]}"; do
      if [[ -d "$dir" ]]; then found="$(cd "$dir" && pwd)"; break; fi
    done
    [[ -n "$found" ]] || die "cannot find manifests dir — set: export MANIFESTS_DIR=<path>"
    MANIFESTS_DIR="$found"
  fi
  log "manifests: ${MANIFESTS_DIR}"

  # 4. Check required secrets — report ALL missing before dying
  local missing=()
  [[ -z "${DB_PASS:-}"    ]] && missing+=("DB_PASS")
  [[ -z "${JWT_SECRET:-}" ]] && missing+=("JWT_SECRET")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing required secrets: ${missing[*]}"
    err "set them and re-run:"
    local v; for v in "${missing[@]}"; do err "  export ${v}='...'"; done
    exit 1
  fi

  # 5. Print deploy summary
  local node_count
  node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf '\n'
  printf '  Cluster:    %s\n' "$cluster"
  printf '  Namespace:  %s\n' "$NAMESPACE"
  printf '  Manifests:  %s\n' "$MANIFESTS_DIR"
  printf '  Nodes:      %s ready\n' "$node_count"
  printf '  Dry-run:    %s\n' "$([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
  printf '\n'

  # 6. Confirm before changing anything — skipped in dry-run and in CI (non-tty)
  if [[ $DRY_RUN -eq 0 && -t 0 ]]; then
    printf 'Proceed with deploy? [y/N] '
    read -r confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] \
      || { log "aborted by user"; exit 0; }
  fi

  phase_ok "preflight complete — namespace=${NAMESPACE}"
}
