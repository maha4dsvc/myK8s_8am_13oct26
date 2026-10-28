{{/* Name for every object: <release>-<chart>, e.g. booking-dev-myjavaapp */}}
{{- define "myjavaapp.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels the Service uses to find the pods. Must never change after install. */}}
{{- define "myjavaapp.selectorLabels" -}}
app: {{ .Chart.Name }}
release: {{ .Release.Name }}
{{- end -}}

{{/* All labels: selector labels + version info */}}
{{- define "myjavaapp.labels" -}}
{{ include "myjavaapp.selectorLabels" . }}
version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
