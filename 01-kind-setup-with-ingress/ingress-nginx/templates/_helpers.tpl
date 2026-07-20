{{/*
Namespace to deploy all resources into.
*/}}
{{- define "ingress-nginx.namespace" -}}
{{- .Values.namespace | default "ingress-nginx" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "ingress-nginx.labels" -}}
app.kubernetes.io/name: ingress-nginx
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: ingress-nginx
{{- end }}

{{/*
Controller-component labels.
*/}}
{{- define "ingress-nginx.controller.labels" -}}
{{ include "ingress-nginx.labels" . }}
app.kubernetes.io/component: controller
{{- end }}

{{/*
Admission-webhook-component labels.
*/}}
{{- define "ingress-nginx.admission.labels" -}}
{{ include "ingress-nginx.labels" . }}
app.kubernetes.io/component: admission-webhook
{{- end }}

{{/*
Controller pod selector labels (subset used in matchLabels and Service selector).
*/}}
{{- define "ingress-nginx.controller.selectorLabels" -}}
app.kubernetes.io/name: ingress-nginx
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: controller
{{- end }}

{{/*
Full controller image reference.
If .Values.controller.image.digest is non-empty the image is pinned by digest:
  repository:tag@digest
Otherwise only tag is used:
  repository:tag
*/}}
{{- define "ingress-nginx.controller.image" -}}
{{- $img := .Values.controller.image -}}
{{- if $img.digest -}}
{{ $img.repository }}:{{ $img.tag }}@{{ $img.digest }}
{{- else -}}
{{ $img.repository }}:{{ $img.tag }}
{{- end -}}
{{- end }}

{{/*
Full webhook certgen image reference (same digest logic as above).
*/}}
{{- define "ingress-nginx.webhook.image" -}}
{{- $img := .Values.admissionWebhooks.image -}}
{{- if $img.digest -}}
{{ $img.repository }}:{{ $img.tag }}@{{ $img.digest }}
{{- else -}}
{{ $img.repository }}:{{ $img.tag }}
{{- end -}}
{{- end }}
