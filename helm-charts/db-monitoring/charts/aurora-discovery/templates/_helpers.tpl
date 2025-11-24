{{/*
Expand the name of the chart.
*/}}
{{- define "aurora-discovery.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "aurora-discovery.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "aurora-discovery.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "aurora-discovery.labels" -}}
helm.sh/chart: {{ include "aurora-discovery.chart" . }}
{{ include "aurora-discovery.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "aurora-discovery.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aurora-discovery.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "aurora-discovery.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "aurora-discovery.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get AWS region from global or local values
*/}}
{{- define "aurora-discovery.awsRegion" -}}
{{- if .Values.aws.region }}
{{- .Values.aws.region }}
{{- else if .Values.global.region }}
{{- .Values.global.region }}
{{- else }}
{{- "us-east-1" }}
{{- end }}
{{- end }}

{{/*
Get namespace from global or local values
*/}}
{{- define "aurora-discovery.namespace" -}}
{{- .Release.Namespace }}
{{- end }}