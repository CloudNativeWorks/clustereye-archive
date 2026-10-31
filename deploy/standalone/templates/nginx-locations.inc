# Shared between HTTPS and HTTP/h2c server blocks.
# Included from /etc/nginx/conf.d/clustereye.conf

keepalive_timeout             365d;
client_header_timeout         365d;
client_body_timeout           365d;
send_timeout                  365d;
grpc_read_timeout             365d;
grpc_send_timeout             365d;

# Security headers (CSP, frame, sniffing, referrer, HSTS). Re-included in
# every location below that sets its own add_header — see that file.
include /etc/clustereye/nginx-security-headers.inc;

client_max_body_size 50m;

root /usr/share/clustereye/web;
index index.html;

# ═══════════════════════════════════════════════
# gRPC location — matches known service paths
# AND catches any gRPC by content-type via @grpc
# ═══════════════════════════════════════════════
location ~ ^/(agent\.|grpc\.|clustereye\.) {
    grpc_pass grpc://grpc_backend;

    grpc_read_timeout       365d;
    grpc_send_timeout       365d;
    client_body_timeout     365d;
    send_timeout            365d;
    proxy_read_timeout      365d;
    proxy_send_timeout      365d;
    grpc_buffer_size        64k;

    grpc_set_header         Host              $host;
    grpc_set_header         X-Real-IP         $remote_addr;
    grpc_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
    grpc_set_header         X-Forwarded-Proto $scheme;

    error_page 502 = @grpc_error_502;
    error_page 503 = @grpc_error_503;
    error_page 504 = @grpc_error_504;
}

# Named gRPC location — fallback for gRPC detected by content-type
location @grpc {
    grpc_pass grpc://grpc_backend;

    grpc_read_timeout       365d;
    grpc_send_timeout       365d;
    client_body_timeout     365d;
    send_timeout            365d;
    proxy_read_timeout      365d;
    proxy_send_timeout      365d;
    grpc_buffer_size        64k;

    grpc_set_header         Host              $host;
    grpc_set_header         X-Real-IP         $remote_addr;
    grpc_set_header         X-Forwarded-For   $proxy_add_x_forwarded_for;
    grpc_set_header         X-Forwarded-Proto $scheme;

    error_page 502 = @grpc_error_502;
    error_page 503 = @grpc_error_503;
    error_page 504 = @grpc_error_504;
}

# ═══════════════════════════════════════════════
# Default route
# Priority: CORS preflight → gRPC (content-type) → CEFE → static
#
# CORS is the API's decision (server.yml cors.allow_origins; the API's own
# host is always allowed). nginx adds no CORS headers: it used to append
# "Access-Control-Allow-Origin: *" with credentials to every response, on top
# of the API's own (pentest 2026-09). A preflight carries no CEFE header, so
# it is routed to the API explicitly.
# ═══════════════════════════════════════════════
location / {
    if ($request_method = 'OPTIONS') {
        error_page 418 = @api;
        return 418;
    }

    if ($is_grpc) {
        error_page 419 = @grpc;
        return 419;
    }

    if ($is_cefe) {
        error_page 418 = @api;
        return 418;
    }

    try_files $uri $uri/ /index.html;
}

# Named location: API proxy (CEFE header match)
location @api {
    proxy_pass              http://api_backend;
    proxy_http_version      1.1;
    proxy_set_header        Host              $host;
    proxy_set_header        X-Real-IP         $remote_addr;
    proxy_set_header        X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Proto $scheme;
    proxy_set_header        Connection        "";
    proxy_buffering         off;
    proxy_request_buffering off;
    proxy_read_timeout      300s;
    proxy_send_timeout      300s;

    # The API sets these too; nginx's (inherited from the server level) are
    # the single copy, so a browser never sees two conflicting values.
    proxy_hide_header       X-Frame-Options;
    proxy_hide_header       X-Content-Type-Options;
    proxy_hide_header       Referrer-Policy;
    proxy_hide_header       Strict-Transport-Security;
    proxy_hide_header       Content-Security-Policy;
}

# Static asset caching
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    include /etc/clustereye/nginx-security-headers.inc;
    try_files $uri =404;
}

# config.js is rendered per install and must not be cached for a year.
location = /config.js {
    add_header Cache-Control "no-cache" always;
    include /etc/clustereye/nginx-security-headers.inc;
    try_files $uri =404;
}

location = /index.html {
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    include /etc/clustereye/nginx-security-headers.inc;
    try_files $uri =404;
}

# gRPC error responses
location @grpc_error_502 { internal; default_type application/grpc; add_header grpc-status 14; add_header grpc-message "upstream unavailable"; return 204; }
location @grpc_error_503 { internal; default_type application/grpc; add_header grpc-status 14; add_header grpc-message "upstream unavailable"; return 204; }
location @grpc_error_504 { internal; default_type application/grpc; add_header grpc-status 4;  add_header grpc-message "deadline exceeded";    return 204; }
