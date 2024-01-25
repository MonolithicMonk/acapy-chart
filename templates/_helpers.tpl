{{/*
Expand the name of the chart.
*/}}
{{- define "global.name" -}}
{{- default .Chart.Name .Values.global.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "global.fullname" -}}
{{- if .Values.global.fullnameOverride }}
{{- .Values.global.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.global.nameOverride }}
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
{{- define "global.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}


{{/*
Create the name for the password secret key. TODO currently not used, either delete or migrate key generation to template function
*/}}
{{- define "global.dbPasswordKey" -}}
{{- if .Values.global.persistence.existingSecret -}}
  {{- .Values.global.persistence.existingSecretKey -}}
{{- else -}}
  postgresql-password
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified acapy name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "acapy.fullname" -}}
{{ template "global.fullname" . }}
{{- end -}}

{{/*
Common acapy labels
*/}}
{{- define "acapy.labels" -}}
helm.sh/chart: {{ include "global.chart" . }}
{{ include "acapy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector acapy labels
*/}}
{{- define "acapy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "global.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "acapy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "acapy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
generate hosts if not overriden
*/}}
{{- define "acapy.host" -}}
{{- if .Values.ingress.hosts -}}
{{- (index .Values.ingress.hosts 0).host -}}
{{- else }}
{{- include "acapy.fullname" . }}{{ .Values.global.ingressSuffix -}}
{{- end -}}
{{- end }}

{{/*
generate ledger browser url
*/}}
{{- define "acapy.ledgerBrowser" -}}
{{- $ledgerBrowser := dict "idu" "" "bcovrin-test" "http://test.bcovrin.vonx.io" -}}
{{ get $ledgerBrowser .Values.global.ledger }}
{{- end }}

{{/*
Get the password secret.
*/}}
{{- define "acapy.secretName" -}}
{{- if .Values.existingSecret -}}
    {{- printf "%s" (tpl .Values.existingSecret $) -}}
{{- else -}}
    {{- printf "%s" (include "acapy.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return true if we should use an existingSecret.
*/}}
{{- define "acapy.useExistingSecret" -}}
{{- if .Values.existingSecret -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created
*/}}
{{- define "acapy.createSecret" -}}
{{- if not (include "acapy.useExistingSecret" .) -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return acapy initialization call
*/}}
{{- define "acapy.registerLedger" -}}
{{- if (eq .Values.global.ledger "bcovrin-test") -}}
curl -d '{\"seed\":\"$(ACAPY_WALLET_SEED)\", \"role\":\"TRUST_ANCHOR\", \"alias\":\"{{ include "acapy.fullname" . }}\"}' -X POST {{ include "acapy.ledgerBrowser" . }}/register;
{{- end -}}
{{- end -}}

{{/*
Return acapy label
*/}}
{{- define "acapy.label" -}}
{{- if .Values.labelOverride -}}
    {{- .Values.labelOverride }} 
{{- else -}} 
    {{- .Release.Name }}     
{{- end -}}
{{- end -}}

{{/*
generate tails baseUrl
*/}}
{{- define "acapy.tails.baseUrl" -}}
{{- $tailsBaseUrl := dict "bcovrin-test" "https://tails-test.vonx.io" "idu" (printf "https://tails%s" .Values.global.ingressSuffix) -}}
{{ .Values.tails.baseUrlOverride | default ( get $tailsBaseUrl .Values.global.ledger ) }}
{{- end }}

{{/*
generate tails uploadUrl
*/}}
{{- define "acapy.tails.uploadUrl" -}}
{{- $tailsUploadUrl:= dict "bcovrin-test" "https://tails-test.vonx.io" "idu" "http://idu-tails:6543" -}}
{{ .Values.tails.uploadUrlOverride| default ( get $tailsUploadUrl .Values.global.ledger ) }}
{{- end }}

{{/*
determine if write ledger
*/}}
{{- define "acapy.writeLedger" -}}
{{- $top := index . 0 -}}
{{- $ledgerName := index . 1 "ledger" -}}
{{- if and (eq $top.Values.global.ledger $ledgerName) (not $top.Values.readOnlyMode) -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}


{{/*
determine acapy database hostname
*/}}
{{- define "acapy.dbHost" -}}
  {{ .Values.db.host }}
{{- end -}}

{{/*
determine acapy database port
*/}}
{{- define "acapy.dbPort" -}}
    {{ .Values.db.port }}
{{- end -}}
