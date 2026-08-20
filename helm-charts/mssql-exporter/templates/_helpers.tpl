{{/*
=============================================================================
MSSQL Exporter — Helm Template Helpers
=============================================================================
*/}}

{{/*
차트 이름 반환
*/}}
{{- define "mssql-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
풀네임 생성 (릴리스명-차트명)
*/}}
{{- define "mssql-exporter.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
차트 레이블 (chart: name-version)
*/}}
{{- define "mssql-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
공통 레이블 셋
*/}}
{{- define "mssql-exporter.labels" -}}
helm.sh/chart: {{ include "mssql-exporter.chart" . }}
{{ include "mssql-exporter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
셀렉터 레이블 (matchLabels에 사용)
*/}}
{{- define "mssql-exporter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mssql-exporter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
서비스 어카운트 이름 반환
*/}}
{{- define "mssql-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mssql-exporter.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
