{{- define "ln-ssdf-vault.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ln-ssdf-vault.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "ln-ssdf-vault.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
