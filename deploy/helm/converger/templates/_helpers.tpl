{{- define "converger.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "converger.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "converger.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "converger.baseLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: converger
{{- end -}}

{{- define "converger.baseLabels" -}}
app.kubernetes.io/name: {{ include "converger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Labels that select the server pods (Deployment, Services, PDB). */}}
{{- define "converger.selectorLabels" -}}
{{ include "converger.baseLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "converger.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "converger.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "converger.secretName" -}}
{{- if .Values.secret.create -}}
{{- include "converger.fullname" . -}}
{{- else -}}
{{- required "existingSecret is required (or set secret.create=true)" .Values.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "converger.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}
{{- end -}}

{{/* Environment of the server pods. */}}
{{- define "converger.envFrom" -}}
- configMapRef:
    name: {{ include "converger.fullname" . }}
- secretRef:
    name: {{ include "converger.secretName" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end -}}
