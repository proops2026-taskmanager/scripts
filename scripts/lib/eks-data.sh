# shellcheck shell=bash
# eks-data.sh — Secrets, ConfigMaps, StorageClass, StatefulSets, Migrations.
# Sourced by deploy-eks.sh. Requires NAMESPACE, MANIFESTS_DIR, DRY_RUN, SCRIPT_DIR,
# DB_PASS, JWT_SECRET, and the helpers from eks-common.sh to already be in scope.

# ── Phase 1: Secrets ─────────────────────────────────────────────────────────
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
# gp2-retain must exist before StatefulSets — DB PVCs reference it.
# Retain policy keeps the EBS volume alive even if the PVC is deleted, preventing
# accidental data loss when tearing down and re-deploying the cluster.
phase_storage() {
  phase_start "storage" "ensuring gp2-retain StorageClass exists"

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

  for pod in db-user-0 db-task-0; do
    log "waiting for ${pod} Ready (timeout 120s)"
    kubectl wait pod "${pod}" \
      --namespace="${NAMESPACE}" \
      --for=condition=Ready \
      --timeout=120s \
      || die "${pod} not Ready — check: kubectl describe pod ${pod} -n ${NAMESPACE}"
  done

  # ── users DB ─────────────────────────────────────────────────────────────
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

  # ── tasks DB ─────────────────────────────────────────────────────────────
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
