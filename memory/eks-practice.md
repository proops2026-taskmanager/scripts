# EKS Practice — Agent Reference

## 1. Create Cluster

```bash
# Prerequisites: source aws-session-init.sh first
eksctl create cluster -f eks/cluster.yaml
# Takes 15-20 min — CloudFormation creates control plane + nodegroup
```

**cluster.yaml must-haves:**

| Field | Value | Reason |
|-------|-------|--------|
| `vpc.nat.gateway` | `Disable` | Saves $30/mo; public subnet nodes need no NAT |
| `managedNodeGroups[].spot` | `true` | 70% cheaper than on-demand |
| `managedNodeGroups[].privateNetworking` | `false` | Public subnet — no NAT |
| `managedNodeGroups[].desiredCapacity` | `1` | Minimum for lab |
| `managedNodeGroups[].instanceTypes` | `[t3.medium]` | Adequate for multi-service |
| `vpc.id` | existing VPC id | Bypass CloudFormation tag enforcement policy |
| `addons[].name` | `aws-ebs-csi-driver` | Required for PVC provisioning |

---

## 2. Connect to Cluster

```bash
aws eks update-kubeconfig --region eu-central-1 --name taskmanager-chau-lab
kubectl get nodes   # wait for Ready
kubectl get pods -n kube-system | grep ebs   # verify EBS CSI running
```

EBS CSI policy must be attached to node role:
```bash
aws iam attach-role-policy \
  --role-name <eksctl-...-NodeInstanceRole-...> \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

---

## 3. ECR Image Push Pattern

```bash
# Build for linux/amd64 (mandatory on M-series Mac)
docker buildx build --platform=linux/amd64 -t <name>:v1 ./<service-dir>

# Push
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.eu-central-1.amazonaws.com
docker tag <name>:v1 <account>.dkr.ecr.eu-central-1.amazonaws.com/<name>:v1
docker push <account>.dkr.ecr.eu-central-1.amazonaws.com/<name>:v1
```

Image URL pattern: `<account-id>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>`

---

## 4. Cost Stack

| Resource | Rate | Notes |
|----------|------|-------|
| EKS control plane | $0.10/hr | Flat fee |
| t3.medium spot (1 node) | ~$0.014/hr | ~70% off on-demand |
| EBS gp2 volumes (3x) | ~$0.002/hr | 10Gi total = $0.10/mo |
| Classic ELB | ~$0.028/hr | Auto-provisioned by LoadBalancer Service |
| **Total** | **~$0.14/hr** | Delete same session to stay under $2 |

NAT Gateway disabled → saves $0.045/hr + data transfer charges.

---

## 5. Skip-List (Out of Scope for Day-1 EKS)

- IRSA / OIDC provider — node IAM role with ECR policy is enough
- AWS Load Balancer Controller / ALB / NLB — Classic ELB auto-provisioned by K8s
- Cluster Autoscaler / Karpenter — fixed 1-node group
- Fargate — EC2 spot is simpler and cheaper for training
- Private API server endpoint — public endpoint for direct kubectl access
- CloudWatch Container Insights — kubectl logs is sufficient

---

## 6. Errors and Fixes

| Error | Root Cause | Fix |
|-------|-----------|-----|
| `exec format error` in pod logs | Image built as arm64 on M-series Mac | Rebuild: `docker buildx build --platform=linux/amd64` |
| `ImagePullBackOff: 401 Unauthorized` | Node IAM role missing ECR policy | Add `AmazonEC2ContainerRegistryReadOnly` to node role |
| `PVC Pending` | EBS CSI driver not installed or missing IAM | `eksctl create addon --name aws-ebs-csi-driver`; attach `AmazonEBSCSIDriverPolicy` to node role |
| `Stack already exists` on create | Previous failed attempt left ROLLBACK_COMPLETE stack | `aws cloudformation update-termination-protection --no-enable-termination-protection` then `aws cloudformation delete-stack` |
| ELB 502 immediately | LB targets not registered yet | Wait 3-8 min; check `aws elb describe-instance-health` → state must be `InService` |
| `kubectl Unauthorized` | Wrong AWS profile or expired token | `source ./scripts/aws-session-init.sh` |
| PostgreSQL `initdb: directory not empty` | EBS volume has `lost+found` dir from ext4 format | Set `PGDATA: /var/lib/postgresql/data/pgdata` in StatefulSet env |
| Redis replicas 1/3 timeout | Default bitnami/redis uses replication mode, needs 3 nodes | Set `architecture: standalone` in Helm values |
| Cross-AZ PVC mount failure | Node in AZ-a, PVC created in AZ-b | `kubectl delete pvc` + `helm uninstall` + reinstall |

---

## 7. Delete and Verify Sequence (Mandatory — Run Before Session End)

```bash
# Step 1 — Helm uninstall (releases PVCs before cluster delete)
helm uninstall my-redis

# Step 2 — Delete cluster (--wait blocks until CloudFormation stacks gone)
eksctl delete cluster --name taskmanager-chau-lab --region eu-central-1 --wait

# Step 3 — Verify cluster gone
eksctl get cluster --region eu-central-1          # must return empty
aws eks list-clusters --region eu-central-1       # must return: {"clusters": []}

# Step 4 — Orphan sweep
# EC2 → Volumes: any tagged with cluster name? Delete manually
# EC2 → Load Balancers: ELB from LoadBalancer Service? Delete manually
# ECR repos: kept (no cost unless images pushed)
```

If `eksctl delete` fails: re-run once. If still fails → manual console cleanup.
Do NOT end the session with partial resources running.
