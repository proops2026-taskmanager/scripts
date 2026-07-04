# k3s Observability Pipeline (G-34)

Closes `docs/WIP.md` G-34 — the `High 5xx Error Rate` and `PodRestartLoop`
Grafana Cloud alert rules existed with correct `runbook_url` annotations but
had no real metrics behind them. There was no monitoring stack running on
this cluster at all (`kube-prometheus-stack` was deleted per G-32 and never
reinstalled), and `capstone-app`'s own `http_requests_total` counter had no
`status` label, so the 5xx query could never match real data even with a
working pipeline.

## What's here

- `grafana-alloy.yaml` — ConfigMap + Deployment for a single lightweight
  [Grafana Alloy](https://grafana.com/docs/alloy/latest/) pod (the
  actively-developed successor to Grafana Agent, which is in maintenance
  mode). Scrapes two targets and remote-writes to Grafana Cloud:
  - `kube-state-metrics.kube-system.svc.cluster.local:8080` → provides
    `kube_pod_container_status_restarts_total` for `PodRestartLoop`
  - `capstone-app.app.svc.cluster.local:80` → the app's own `/metrics`,
    provides `http_requests_total{status=...}` for `High 5xx Error Rate`
    (status label added in `capstone/app/app.py` via an `after_request`
    hook — see chautv-proops2026 PR #2)

  Deliberately NOT a full `kube-prometheus-stack` reinstall — this cluster
  is a single `t3.small` node and only 2 alert rules need real data.

- `kube-state-metrics` is deployed via the upstream kustomize target, not a
  file in this repo:
  ```bash
  sudo kubectl apply -k "github.com/kubernetes/kube-state-metrics/examples/standard?ref=v2.19.1"
  ```

## Reproducing from scratch

```bash
# 1. kube-state-metrics
sudo kubectl apply -k "github.com/kubernetes/kube-state-metrics/examples/standard?ref=v2.19.1"

# 2. Grafana Cloud remote-write credentials (get these from Grafana Cloud UI:
#    Connections > Prometheus for the username/instance ID, Administration >
#    Access Policies for a metrics:write-scoped token — NOT a Service Account
#    token, those are for the read API)
sudo kubectl create secret generic grafana-cloud-prom -n kube-system \
  --from-literal=username='<instance-id>' \
  --from-literal=password='<metrics:write access policy token>'

# 3. Alloy
sudo kubectl apply -f grafana-alloy.yaml
```

## Allowlist

The `write_relabel_config` in `grafana-alloy.yaml` only forwards:
`up`, `kube_pod_container_status_restarts_total`, `kube_pod_info`,
`http_requests_total`. Deliberately tight — this is a demo cluster, not the
old EKS taskmanager-dev setup (see `chautv-proops2026/monitoring/values-prom.yaml`
for that one, which is for a different, now-destroyed cluster and includes
`ingress-nginx`/`nginx_ingress_controller_*` metrics that don't apply here —
that's actually where the `High 5xx Error Rate` alert's original
`namespace="ingress-nginx"` query assumption came from).

## Verified working (2026-07-04)

- `kube_pod_container_status_restarts_total{namespace="app"}` — returning data
- `http_requests_total{status="200"}` — returning data (`/health`, `/`)
- `High 5xx Error Rate` — state: normal
- `PodRestartLoop` — state: normal

## Grafana rule config note

`High 5xx Error Rate`'s "Alert state if no data" is set to **OK** (not the
default "No Data"). With zero 5xx traffic, the `status=~"5.."` numerator
genuinely has no series — that's the healthy case, not an unknown/broken
one, so NoData would misreport a healthy demo as ambiguous. `PodRestartLoop`
doesn't need this since `kube_pod_container_status_restarts_total` always
has a series (value 0 when nothing is restarting).
- Remote-write: 0 failed samples, allowlist correctly dropping non-matching series
