{{- define "ai-bankapp.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s%s%s" .Release.Name (ternary "-" "" (ne .Values.nameOverride "")) .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ai-bankapp.labels" -}}
app.kubernetes.io/name: {{ include "ai-bankapp.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "ai-bankapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-bankapp.fullname" . }}
{{- end -}}

{{- define "ai-bankapp.componentLabels" -}}
app.kubernetes.io/name: {{ include "ai-bankapp.fullname" .root }}-{{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "ai-bankapp.componentSelectorLabels" -}}
app.kubernetes.io/name: {{ include "ai-bankapp.fullname" .root }}-{{ .component }}
{{- end -}}

{{- define "ai-bankapp.serviceAccountName" -}}
{{- default (include "ai-bankapp.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}
