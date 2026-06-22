# Day 36 Substrate Check

**Date:** 2026-06-21

## Checklist

| Component | Status | Notes |
|-----------|--------|-------|
| EC2 i-0f277a90657999094 | ✅ | Was already running (3.76.55.12) |
| k3s node Ready | ✅ | `kubectl get nodes` → Ready (v1.35.5+k3s1) |
| app namespace pod Running | ✅ | `capstone-app-57887bcdc5-pl2zh` Running |
| monitoring namespace (kube-prom + Loki) | ⚠️ skipped | Not deployed; not required for Day 36 |
| Agent A ngrok URL | ✅ | https://ovary-stifling-feline.ngrok-free.dev |
| Agent A smoke test | ✅ | 200 received; agent dispatched; Discord posted |

## Results

- Cluster: Y
- Dashboard (Grafana Cloud): skipped (monitoring not deployed; sample alert used directly)
- Agent A wakes on smoke test: Y — posted "Diagnosis: Cannot confirm — namespace taskmanager-dev not found on k3s (expected, smoke test payload used wrong ns)"
- ngrok URL: https://ovary-stifling-feline.ngrok-free.dev (2026-06-22 session)

## Notes

- SG port 6443 updated from 113.161.43.10 → 42.115.164.91 (current laptop IP)
- kubeconfig saved to ~/.kube/k3s-capstone.yaml with insecure-skip-tls-verify: true
- AC-03/AC-04 live test alerts must use namespace `app` (not `taskmanager-dev`) — only `app` ns exists in k3s
