{{/*
Namespace for all resources.
*/}}
{{- define "keycloak.namespace" -}}
{{- .Values.namespace | default "keycloak" }}
{{- end }}

{{/*
Common labels for Keycloak resources.
*/}}
{{- define "keycloak.labels" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: keycloak
{{- end }}

{{/*
Selector labels for the Keycloak pod (used in Deployment + Service).
*/}}
{{- define "keycloak.selectorLabels" -}}
app: keycloak
{{- end }}

{{/*
Full Keycloak container image reference.
*/}}
{{- define "keycloak.image" -}}
{{ .Values.keycloak.image.repository }}:{{ .Values.keycloak.image.tag }}
{{- end }}

{{/*
Common labels for PostgreSQL resources.
*/}}
{{- define "postgresql.labels" -}}
app.kubernetes.io/name: keycloak-postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: keycloak
{{- end }}

{{/*
Selector labels for the PostgreSQL pod.
*/}}
{{- define "postgresql.selectorLabels" -}}
app: keycloak-postgresql
{{- end }}

{{/*
Full PostgreSQL container image reference.
*/}}
{{- define "postgresql.image" -}}
{{ .Values.postgresql.image.repository }}:{{ .Values.postgresql.image.tag }}
{{- end }}
