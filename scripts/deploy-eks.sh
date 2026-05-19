#!/usr/bin/env bash
# deploy-eks.sh — Apply taskmanager EKS manifests to the cluster.
# Skips any Deployment whose running image already matches the manifest.
# Usage: deploy-eks.sh [--dry-run] [--namespace <ns>] [--help]
set -euo pipefail

# Explicit PATH — required for cron/CI (IRD-19 Pattern 6)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# ── Configuration (override via env vars) ────────────────────────────────────
NAMESPACE="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${MANIFESTS_DIR:-${SCRIPT_DIR}/../eks/manifests}"
DRY_RUN=0

# ── Source lib files (order matters — common must be first) ──────────────────
# shellcheck source=lib/eks-common.sh
source "${SCRIPT_DIR}/lib/eks-common.sh"
# shellcheck source=lib/eks-data.sh
source "${SCRIPT_DIR}/lib/eks-data.sh"
# shellcheck source=lib/eks-app.sh
source "${SCRIPT_DIR}/lib/eks-app.sh"
# shellcheck source=lib/eks-infra.sh
source "${SCRIPT_DIR}/lib/eks-infra.sh"

# ── Argument parsing (IRD-19 Pattern 2) ──────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --namespace)            shift; [[ $# -ge 1 ]] || die "--namespace requires a value"
                            NAMESPACE="$1"; shift ;;
    --help|-h)              usage ;;
    *)                      die "unknown argument: $1" ;;
  esac
done

# ── Tool preflight (IRD-19 Pattern 6) ────────────────────────────────────────
for tool in kubectl helm aws; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ $DRY_RUN -eq 1 ]] && log "DRY-RUN mode — no state will be changed"

  preflight          # cluster discovery, kubeconfig, secrets check, confirm prompt

  phase_secrets      # Phase 1  — K8s Secrets (DB passwords, JWT)
  phase_configmaps   # Phase 2  — K8s ConfigMaps (env vars)
  phase_storage      # Phase 3  — StorageClass must exist before PVCs are created
  phase_statefulsets # Phase 4  — PostgreSQL StatefulSets
  phase_migrate      # Phase 5  — DB schema migrations (idempotent)
  phase_deployments  # Phase 6  — App Deployments (image-level idempotency check)
  phase_redis        # Phase 7  — Redis via Helm
  phase_rollout      # Phase 8  — Wait for all Deployments Ready
  phase_controller   # Phase 9  — ingress-nginx controller (cluster infra, once per cluster)
  phase_ingress      # Phase 10 — Ingress routing rules + ELB URL
  phase_hpa          # Phase 11 — Metrics Server + HPA objects

  log "OK    deploy complete — namespace=${NAMESPACE}"
  kubectl get pods --namespace="${NAMESPACE}"
}

main "$@"
