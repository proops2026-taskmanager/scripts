# eks-infra.sh — Ingress Controller, Ingress routing rules, HPA + Metrics Server.
# Sourced by deploy-eks.sh. Requires NAMESPACE, MANIFESTS_DIR, DRY_RUN,
# and the helpers from eks-common.sh to already be in scope.

# ── Phase 9: Ingress Controller ───────────────────────────────────────────────
# The Ingress Controller is cluster infrastructure — installed once per cluster,
# not per app. ingress.yaml (Phase 10) is just routing config; without the
# controller pod running and watching for it, Ingress objects are dead config.
# Idempotent: helm upgrade --install is a no-op if already at the same version.
phase_controller() {
  phase_start "controller" "ensuring ingress-nginx controller is installed"

  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  run helm repo update

  run helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --wait --timeout=5m

  if [[ $DRY_RUN -eq 1 ]]; then
    phase_ok "controller installed (dry-run)"
    return 0
  fi

  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s \
    || die "ingress-nginx controller pod did not become Ready — check: kubectl get pods -n ingress-nginx"

  phase_ok "ingress-nginx controller ready"
}

# ── Phase 10: Ingress ─────────────────────────────────────────────────────────
# Applied after all backend Services exist. Polls for ELB hostname so the
# operator gets a clickable URL at the end of the deploy.
phase_ingress() {
  phase_start "ingress" "applying Ingress resources"

  run kubectl apply -f "${MANIFESTS_DIR}/ingress.yaml"

  if [[ $DRY_RUN -eq 1 ]]; then
    phase_ok "ingress applied (dry-run)"
    return 0
  fi

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

# ── Phase 11: HPA ─────────────────────────────────────────────────────────────
# Metrics Server must be installed first — HPA reads CPU/mem from it every 15s.
# EKS 1.24+ pre-installs its own Metrics Server build; applying the official
# manifest over it fails on immutable selector fields. Skip install when the
# deployment already exists; patch the service selector if endpoints are empty.
phase_hpa() {
  phase_start "hpa" "installing Metrics Server + applying HPAs"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "SKIP  HPA in dry-run mode"
    phase_ok "HPA applied (dry-run)"
    return 0
  fi

  if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    log "metrics-server already installed — skipping install"
  else
    log "metrics-server not found — installing from official manifest"
    run kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  fi

  kubectl wait deployment metrics-server \
    --namespace kube-system \
    --for=condition=available \
    --timeout=120s \
    || die "metrics-server did not become Ready — check: kubectl get pods -n kube-system"

  run kubectl apply -f "${MANIFESTS_DIR}/hpa.yaml"

  phase_ok "HPAs applied — use: kubectl get hpa to monitor"
}
