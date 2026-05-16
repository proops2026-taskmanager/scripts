#!/usr/bin/env bash
set -euo pipefail

ACCOUNT="905418181527"
REGION="ap-southeast-1"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
SERVICES=("user-service" "task-service" "api-gateway" "frontend-service" "notification-service")
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Authenticating Docker to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

for svc in "${SERVICES[@]}"; do
  echo "==> Building $svc (linux/amd64)"
  docker buildx build \
    --platform linux/amd64 \
    --push \
    -t "$REGISTRY/$svc:v1" \
    "${REPO_ROOT}/${svc}"
  echo "==> Done: $svc"
done

echo "==> All images pushed to ECR"
