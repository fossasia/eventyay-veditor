{{- define "sreview.render_template" }}
  {{- if typeIs "string" .value }}
    {{- tpl .value .context }}
  {{- else }}
    {{- tpl (.value | toYaml) .context }}
  {{- end }}
{{- end }}
{{- define "sreview.envvals" }}
envFrom:
- configMapRef:
    name: {{ .Release.Name }}-config
env:
- name: SREVIEWSECRET_NAME
  value: {{ .Release.Name }}-secret
{{- if .Values.use_internal_pg }}
- name: SREVIEW_DBICOMPONENTS
  value: "host password dbname user"
- name: SREVIEW_DBI_USER
  value: "postgres"
- name: SREVIEW_DBI_HOST
  value: {{ .Release.Name }}-postgresql
- name: SREVIEW_DBI_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-postgresql
      key: postgres-password
- name: SREVIEW_DBI_DBNAME
  value: "postgres"
{{- else }}
- name: SREVIEW_DBISTRING
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-secret
      key: SREVIEW_DBISTRING
{{- end }}
{{- if .Values.use_internal_minio }}
- name: SREVIEW_S3_DEFAULT_ACCESSKEY
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-minio
      key: {{ .Values.minioAccount | default "root" }}User
- name: SREVIEW_S3_DEFAULT_SECRETKEY
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-minio
      key: {{ .Values.minioAccount | default "root" }}Password
- name: SREVIEW_S3_DEFAULT_HOST
  value: {{ .Release.Name }}-minio:9000
- name: SREVIEW_S3_DEFAULT_SECURE
  value: "0"
{{- else }}
- name: SREVIEW_S3_ACCESS_CONFIG
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-secret
      key: SREVIEW_S3_ACCESS_CONFIG
{{- end }}
- name: SREVIEW_ADMINPW
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-secret
      key: SREVIEW_ADMINPW
- name: SREVIEW_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Release.Name }}-secret
      key: SREVIEW_API_KEY
{{- with .Values.extraEnv }}
{{  include "sreview.render_template" (dict "value" . "context" $) }}
{{- end }}
{{- with .Values.secret }}
{{- with .extraEnv }}
{{  include "sreview.render_template" (dict "value" . "context" $) }}
{{- end }}
{{- end }}
{{- end }}
