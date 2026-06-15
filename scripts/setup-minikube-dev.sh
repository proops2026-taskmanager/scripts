#!/usr/bin/env bash
# setup-minikube-dev.sh
#
# Bootstrap minikube with the full taskmanager stack (no AWS needed).
# Run this ONCE before triggering the CI/CD pipelines.
#
# Pre-requisites:
#   - Docker Desktop running
#   - minikube running  (minikube start --kubernetes-version=v1.30.0)
#   - kubectl configured to minikube context
#
# What this script creates:
#   - In-cluster postgres for users_db and tasks_db
#   - In-cluster redis
#   - ConfigMaps (in-cluster URLs override EKS/RDS values)
#   - Secrets (test values — not production)
#   - Stub Deployments + Services for all 4 app services
#     (CD pipelines will replace the images via kubectl set image)
#
# Usage:
#   bash scripts/setup-minikube-dev.sh

set -euo pipefail

NAMESPACE=default
CLUSTER_NAME=minikube

echo ""
echo "=== taskmanager minikube bootstrap ==="
echo ""

# ── Guard ─────────────────────────────────────────────────────────────────────
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "$CURRENT_CTX" != "minikube" ]]; then
  echo "ERROR: kubectl context is '$CURRENT_CTX', expected 'minikube'."
  echo "Run: kubectl config use-context minikube"
  exit 1
fi
echo "Context: $CURRENT_CTX ✓"

# ── Step 1: In-cluster Postgres (users_db) ────────────────────────────────────
echo ""
echo "[1/7] Deploying in-cluster postgres for users_db..."
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-user
spec:
  selector:
    matchLabels:
      app: db-user
  replicas: 1
  template:
    metadata:
      labels:
        app: db-user
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_DB
              value: users_db
            - name: POSTGRES_USER
              value: app_user
            - name: POSTGRES_PASSWORD
              value: app_pass_local
          readinessProbe:
            exec:
              command: [pg_isready, -U, app_user, -d, users_db]
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: db-user
spec:
  selector:
    app: db-user
  ports:
    - port: 5432
      targetPort: 5432
EOF

# ── Step 2: In-cluster Postgres (tasks_db) ────────────────────────────────────
echo "[2/7] Deploying in-cluster postgres for tasks_db..."
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db-task
spec:
  selector:
    matchLabels:
      app: db-task
  replicas: 1
  template:
    metadata:
      labels:
        app: db-task
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_DB
              value: tasks_db
            - name: POSTGRES_USER
              value: app_user
            - name: POSTGRES_PASSWORD
              value: app_pass_local
          readinessProbe:
            exec:
              command: [pg_isready, -U, app_user, -d, tasks_db]
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: db-task
spec:
  selector:
    app: db-task
  ports:
    - port: 5432
      targetPort: 5432
EOF

# ── Step 3: In-cluster Redis ──────────────────────────────────────────────────
echo "[3/7] Deploying in-cluster redis..."
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  selector:
    matchLabels:
      app: redis
  replicas: 1
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          readinessProbe:
            exec:
              command: [redis-cli, ping]
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
EOF

# ── Step 4: ConfigMaps ────────────────────────────────────────────────────────
echo "[4/7] Creating ConfigMaps..."
kubectl apply -n $NAMESPACE -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-svc-cm
data:
  PORT: "3001"
  BCRYPT_ROUNDS: "12"
  JWT_EXPIRES_IN: "24h"
  NODE_TLS_REJECT_UNAUTHORIZED: "0"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: task-svc-cm
data:
  PORT: "3002"
  NODE_TLS_REJECT_UNAUTHORIZED: "0"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-gw-cm
data:
  PORT: "8080"
  USER_SERVICE_URL: "http://user-service:3001"
  TASK_SERVICE_URL: "http://task-service:3002"
  CORS_ORIGIN: "*"
  NODE_TLS_REJECT_UNAUTHORIZED: "0"
EOF

# ── Step 5: Secrets ───────────────────────────────────────────────────────────
echo "[5/7] Creating Secrets (test values)..."

kubectl create secret generic user-svc-secret \
  --from-literal=DATABASE_URL="postgresql://app_user:app_pass_local@db-user:5432/users_db" \
  --from-literal=JWT_SECRET="minikube-test-jwt-secret-not-for-production" \
  -n $NAMESPACE \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic task-svc-secret \
  --from-literal=DATABASE_URL="postgresql://app_user:app_pass_local@db-task:5432/tasks_db" \
  --from-literal=REDIS_URL="redis://redis:6379" \
  -n $NAMESPACE \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic api-gw-secret \
  --from-literal=JWT_SECRET="minikube-test-jwt-secret-not-for-production" \
  -n $NAMESPACE \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

# ── Step 6: Stub Deployments + Services ──────────────────────────────────────
# Use nginx:alpine as the initial image. CD pipelines replace it via
# kubectl set image → rollout status. The stub just ensures the Deployment object
# exists so kubectl set image has something to patch.
echo "[6/7] Creating stub Deployments and Services..."
kubectl apply -n $NAMESPACE -f - <<'EOF'
# user-service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: user-service
  template:
    metadata:
      labels:
        app: user-service
    spec:
      containers:
        - name: user-service
          image: nginx:alpine
          ports:
            - containerPort: 3001
          envFrom:
            - configMapRef:
                name: user-svc-cm
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: user-svc-secret
                  key: DATABASE_URL
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: user-svc-secret
                  key: JWT_SECRET
---
apiVersion: v1
kind: Service
metadata:
  name: user-service
spec:
  selector:
    app: user-service
  ports:
    - port: 3001
      targetPort: 3001
---
# task-service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: task-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: task-service
  template:
    metadata:
      labels:
        app: task-service
    spec:
      containers:
        - name: task-service
          image: nginx:alpine
          ports:
            - containerPort: 3002
          envFrom:
            - configMapRef:
                name: task-svc-cm
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: task-svc-secret
                  key: DATABASE_URL
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: task-svc-secret
                  key: REDIS_URL
---
apiVersion: v1
kind: Service
metadata:
  name: task-service
spec:
  selector:
    app: task-service
  ports:
    - port: 3002
      targetPort: 3002
---
# api-gateway
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      containers:
        - name: api-gateway
          image: nginx:alpine
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: api-gw-cm
          env:
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: api-gw-secret
                  key: JWT_SECRET
---
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
spec:
  selector:
    app: api-gateway
  ports:
    - port: 8080
      targetPort: 8080
EOF

# ── Step 7: Wait for postgres and print kubeconfig ────────────────────────────
echo "[7/7] Waiting for postgres pods to be Ready (up to 60s)..."
kubectl wait deployment/db-user -n $NAMESPACE --for=condition=Available --timeout=60s || true
kubectl wait deployment/db-task -n $NAMESPACE --for=condition=Available --timeout=60s || true

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Register self-hosted runner:"
echo "   GitHub → org Settings → Actions → Runners → New → macOS → follow instructions"
echo "   Run the runner in a dedicated terminal: ./run.sh"
echo ""
echo "2. Update KUBE_CONFIG_DATA org secret with minikube kubeconfig:"
echo "   gh secret set KUBE_CONFIG_DATA \\"
echo "     --org proops2026-taskmanager \\"
echo "     --visibility all \\"
echo "     --body \"\$(kubectl config view --raw --minify | base64 | tr -d '\\n')\""
echo ""
echo "3. Push workflow changes to trigger pipelines:"
echo "   git push origin develop   (in each service repo)"
echo ""
echo "Pods:"
kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | awk '{printf "  %-35s %s\n", $1, $3}'
