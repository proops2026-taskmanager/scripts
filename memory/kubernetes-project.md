# Kubernetes — Task Management System Reference

Agent reads this before every K8s task on this project. Tables and bullets only.

---

## Service Table

| Service | K8s Name (metadata.name) | Kind | Port | Namespace |
|---------|--------------------------|------|------|-----------|
| frontend-service | `frontend-service` | Deployment | 3000 | default |
| api-gateway | `api-gateway` | Deployment | 8080 | default |
| user-service | `user-service` | Deployment | 3001 | default |
| task-service | `task-service` | Deployment | 3002 | default |
| db-user | `db-user` | StatefulSet | 5432 | default |
| db-task | `db-task` | StatefulSet | 5432 | default |
| Redis (Helm) | `my-redis-master` | StatefulSet (Helm) | 6379 | default |

---

## ConfigMap vs Secret per Service

| Service | ConfigMap name | Keys | Secret name | Keys |
|---------|---------------|------|-------------|------|
| db-user | db-user-cm | POSTGRES_DB, POSTGRES_USER | db-user-secret | POSTGRES_PASSWORD |
| db-task | db-task-cm | POSTGRES_DB, POSTGRES_USER | db-task-secret | POSTGRES_PASSWORD |
| user-service | user-svc-cm | PORT, BCRYPT_ROUNDS, JWT_EXPIRES_IN | user-svc-secret | DATABASE_URL, JWT_SECRET |
| task-service | task-svc-cm | PORT | task-svc-secret | DATABASE_URL |
| api-gateway | api-gw-cm | PORT, USER_SERVICE_URL, TASK_SERVICE_URL, CORS_ORIGIN | api-gw-secret | JWT_SECRET |
| frontend-service | — | — | — | — |

**Rule:** DATABASE_URL and JWT_SECRET → Secret. Everything else → ConfigMap.

---

## In-Cluster DNS Pattern

Format: `[service-name].[namespace].svc.cluster.local`
Within `default` namespace, shorthand works: just `[service-name]`

| ConfigMap key | Value |
|--------------|-------|
| USER_SERVICE_URL | `http://user-service:3001` |
| TASK_SERVICE_URL | `http://task-service:3002` |
| DATABASE_URL (user-svc) | `postgresql://app_user:app_pass@db-user:5432/users_db` |
| DATABASE_URL (task-svc) | `postgresql://app_user:app_pass@db-task:5432/tasks_db` |
| REDIS_URL (api-gw) | `redis://my-redis-master:6379` |

---

## Apply Order

```
1. kubectl apply -f db-user-cm.yaml db-task-cm.yaml user-svc-cm.yaml task-svc-cm.yaml api-gw-cm.yaml
2. kubectl create secret generic db-user-secret ...
   kubectl create secret generic db-task-secret ...
   kubectl create secret generic user-svc-secret ...
   kubectl create secret generic task-svc-secret ...
   kubectl create secret generic api-gw-secret ...
3. kubectl apply -f db-user-statefulset.yaml
4. kubectl apply -f db-task-statefulset.yaml
5. kubectl rollout status statefulset/db-user   ← wait before step 6
6. kubectl apply -f user-svc-deployment.yaml
7. kubectl apply -f task-svc-deployment.yaml
8. kubectl rollout status deployment/user-service deployment/task-service
9. kubectl apply -f api-gw-deployment.yaml
10. kubectl apply -f frontend-deployment.yaml
11. kubectl apply -f ingress.yaml
```

---

## Ingress Routes

| Path | Backend Service | Port |
|------|----------------|------|
| `/api` (Prefix) | api-gateway | 8080 |
| `/` (Prefix) | frontend-service | 3000 |

**Testing on macOS Docker driver (no external IP):**
```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8888:80 &
curl http://localhost:8888/api/health   # → 200
curl http://localhost:8888/             # → 200
```

---

## Helm Installed Charts

| Release | Chart | Service | Port | Purpose |
|---------|-------|---------|------|---------|
| my-redis | bitnami/redis | my-redis-master | 6379 | Rate-limit counter (api-gateway AC-14) |

---

## Manifest Files

```
k8s/taskmanager/
├── db-user-cm.yaml
├── db-task-cm.yaml
├── user-svc-cm.yaml
├── task-svc-cm.yaml
├── api-gw-cm.yaml
├── db-user-statefulset.yaml     ← includes headless Service
├── db-task-statefulset.yaml     ← includes headless Service
├── user-svc-deployment.yaml     ← includes ClusterIP Service
├── task-svc-deployment.yaml     ← includes ClusterIP Service
├── api-gw-deployment.yaml       ← includes ClusterIP Service
├── frontend-deployment.yaml     ← includes ClusterIP Service
├── ingress.yaml
└── my-redis-values.yaml         ← Helm override file
```

---

## Common Failures Hit

| Symptom | Cause | Fix |
|---------|-------|-----|
| minikube host: Stopped | Clean stop | `minikube start --driver=docker` |
| minikube apiserver: Stopped after Docker Desktop restart | K8S_APISERVER_MISSING | `minikube delete && minikube start --driver=docker` |
| kubectl apply: connection refused | minikube not running | Start minikube first |
| ingress webhook: connection refused | Controller not ready | `kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s` |
| curl to minikube IP times out on macOS | Docker driver — no host route | Port-forward to ingress-nginx controller instead |
