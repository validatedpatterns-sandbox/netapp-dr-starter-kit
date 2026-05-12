{{/*
OpenShift default router: explicit drDnsReconciler *IngressHostname, else router-default.<ingressDomain>.
ingressDomain is global.clusterDomain (primary) / global.drClusterDomain (DR).
*/}}
{{- define "dr-dns-reconciler.routerHostname" -}}
{{- if .explicit -}}
{{- .explicit -}}
{{- else if .domain -}}
router-default.{{ .domain }}
{{- end -}}
{{- end }}

{{- define "dr-dns-reconciler.labels" -}}
app.kubernetes.io/name: dr-dns-reconciler
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Per-app names for Route53 (wordpress.dr.<domain>, …). Prefer drDnsReconciler.apps;
if empty, derive from drFailover.apps so DR routes and DNS stay aligned with one list.
*/}}
{{- define "dr-dns-reconciler.appsJson" -}}
{{- $c := .Values.drDnsReconciler }}
{{- if and $c.apps (gt (len $c.apps) 0) }}
{{- $c.apps | toJson -}}
{{- else }}
{{- $df := .Values.drFailover | default dict }}
{{- if and ($df.apps | default list) (gt (len $df.apps) 0) }}
{{- $list := list }}
{{- range $df.apps }}
{{- $list = append $list (dict "name" .name) }}
{{- end }}
{{- $list | toJson -}}
{{- else }}
{{- "[]" -}}
{{- end }}
{{- end }}
{{- end }}
