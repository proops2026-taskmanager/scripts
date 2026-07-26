{{/*
Standard labels applied to every object in this chart.
{{ include "taskmanager.labels" . }} injects these into metadata.labels.

Why these specific labels?
- app.kubernetes.io/managed-by: lets `helm uninstall` find and delete all objects
- helm.sh/chart: visible in `kubectl get <resource> --show-labels` for debugging
*/}}
{{- define "taskmanager.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Full image reference for a service values block.
Usage: {{ include "taskmanager.image" .Values.userService }}
Returns: repository:tag  e.g.  905418181527.dkr.ecr.../user-service:v1
*/}}
{{- define "taskmanager.image" -}}
{{ .svc.image.repository }}:{{ if .global.imageTag }}{{ .global.imageTag }}{{ else }}{{ .svc.image.tag }}{{ end }}
{{- end }}
