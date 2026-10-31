# /etc/clustereye/nginx-security-headers.inc
# Managed by the ClusterEye standalone installer. Substituted: CE_HSTS_HEADER.
#
# nginx does not merge add_header across levels: a location that declares
# any add_header drops every inherited one. So this file is included at the
# server level AND inside each location that sets its own headers
# (nginx-locations.inc) — otherwise index.html went out with no security
# headers at all (pentest 2026-09).
#
# The UI build moves every inline script of index.html into assets/, so
# script-src is 'self' alone and needs no per-release hashes. Keep this policy
# in step with nginx.conf in the frontend repo (vite-plugins/__tests__/csp.test.ts
# checks both).

add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://cdn.jsdelivr.net; font-src 'self' data:; connect-src 'self' https: wss:; worker-src 'self' blob:; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'" always;
add_header X-Frame-Options           "DENY"                            always;
add_header X-Content-Type-Options    "nosniff"                         always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
add_header Permissions-Policy        "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
${CE_HSTS_HEADER}
