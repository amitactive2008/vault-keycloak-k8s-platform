{{/*
Namespace for all resources.
*/}}
{{- define "webapp.namespace" -}}
{{- .Values.namespace | default "team-a" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "webapp.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Backend image reference.
*/}}
{{- define "webapp.backend.image" -}}
{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}
{{- end }}

{{/*
Frontend image reference.
*/}}
{{- define "webapp.frontend.image" -}}
{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}
{{- end }}

{{/*
PostgreSQL image reference.
*/}}
{{- define "webapp.postgresql.image" -}}
{{ .Values.postgresql.image.repository }}:{{ .Values.postgresql.image.tag }}
{{- end }}
