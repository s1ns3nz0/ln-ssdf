{{- define "ln-ssdf-postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ln-ssdf-postgres.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "ln-ssdf-postgres.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
