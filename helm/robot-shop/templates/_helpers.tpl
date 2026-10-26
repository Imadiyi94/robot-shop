{{/*
Resolve an application image reference, optionally pinned by digest.

PATCH 6: digests live in .Values.image.digests[<name>] and are recorded in
docs/IMAGE_PINS.md. Rendered form: repo/name:tag@sha256:...

Keeping the tag alongside the digest makes the reference readable in
`kubectl describe pod` while the digest remains the authoritative selector.
*/}}
{{- define "robot-shop.image" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $digest := "" -}}
{{- if and $root.Values.image.digests (hasKey $root.Values.image.digests $name) -}}
{{- $digest = index $root.Values.image.digests $name -}}
{{- end -}}
{{- if $digest -}}
{{ $root.Values.image.repo }}/{{ $name }}:{{ $root.Values.image.version }}@{{ $digest }}
{{- else -}}
{{ $root.Values.image.repo }}/{{ $name }}:{{ $root.Values.image.version }}
{{- end -}}
{{- end -}}
