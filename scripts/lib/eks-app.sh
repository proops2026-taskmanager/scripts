# shellcheck shell=bash
# eks-app.sh — Deployments, Redis, rollout health check.
# Sourced by deploy-eks.sh. Requires NAMESPACE, MANIFESTS_DIR, DRY_RUN,
# and the helpers from eks-common.sh to already be in scope.

# ── Phase 6: Deployments (idempotency check per Deployment) ──────────────────
# Reads intended image from the manifest, compares with the running image in the
# cluster. Skips kubectl apply if they already match. Treats "not found" (first
# deploy) as "not deployed → apply".
deploy_one() {
  local name="$1"
  local manifest="$2"

  local intended
  intended=$(awk '/image:/{print $2; exit}' "${manifest}")
  [[ -n "$intended" ]] || die "no 'image:' line found in ${manifest}"

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

# ── Phase 7: Redis (Helm) ─────────────────────────────────────────────────────
phase_redis() {
  phase_start "redis" "installing/upgrading Redis via Helm"

  run helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  run helm repo update
  run helm upgrade --install my-redis bitnami/redis \
    -f "${MANIFESTS_DIR}/my-redis-values.yaml" \
    --namespace="${NAMESPACE}" \
    --wait --timeout=5m

  phase_ok "Redis ready"
}

# ── Phase 8: Rollout status ───────────────────────────────────────────────────
# Uses kubectl rollout status — EKS services have no external port without a
# port-forward; rollout status is the cluster-native observable.
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
