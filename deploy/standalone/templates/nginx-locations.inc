# Shared between HTTPS and HTTP/h2c server blocks.
# Included from /etc/nginx/conf.d/clustereye.conf

keepalive_timeout             365d;
client_header_timeout         365d;
client_body_timeout           365d;
send_timeout                  365d;
grpc_read_timeout             365d;
grpc_send_timeout             365d;

add_header X-Content-Type-Options    "nosniff"     always;
add_header X-Frame-Options           "SAMEORIGIN"  always;
add_header Referrer-Policy           "no-referrer" always;

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
# ═══════════════════════════════════════════════
location / {
    if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin'      '*';
        add_header 'Access-Control-Allow-Methods'     'GET, OPTIONS, POST, PUT, DELETE, PATCH';
        add_header 'Access-Control-Allow-Headers'     'content-type,authorization,x-requested-with,cefe';
        add_header 'Access-Control-Allow-Credentials' 'true';
        add_header 'Access-Control-Max-Age'           '1728000';
        add_header 'Content-Type'                     'text/plain charset=UTF-8';
        add_header 'Content-Length'                    '0';
        return 204;
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

    add_header 'Access-Control-Allow-Origin'      '*' always;
    add_header 'Access-Control-Allow-Methods'     'GET, OPTIONS, POST, PUT, DELETE, PATCH' always;
    add_header 'Access-Control-Allow-Headers'     'content-type,authorization,x-requested-with,cefe' always;
    add_header 'Access-Control-Allow-Credentials' 'true' always;
    add_header 'Access-Control-Expose-Headers'    '*' always;
    add_header 'Access-Control-Max-Age'           '1728000' always;
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

    add_header 'Access-Control-Allow-Origin'      '*' always;
    add_header 'Access-Control-Allow-Methods'     'GET, OPTIONS, POST, PUT, DELETE, PATCH' always;
    add_header 'Access-Control-Allow-Headers'     'content-type,authorization,x-requested-with,cefe' always;
    add_header 'Access-Control-Allow-Credentials' 'true' always;
    add_header 'Access-Control-Expose-Headers'    '*' always;
    add_header 'Access-Control-Max-Age'           '1728000' always;
}

# Static asset caching
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    try_files $uri =404;
}

location = /index.html {
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    try_files $uri =404;
}

# gRPC error responses
location @grpc_error_502 { internal; default_type application/grpc; add_header grpc-status 14; add_header grpc-message "upstream unavailable"; return 204; }
location @grpc_error_503 { internal; default_type application/grpc; add_header grpc-status 14; add_header grpc-message "upstream unavailable"; return 204; }
location @grpc_error_504 { internal; default_type application/grpc; add_header grpc-status 4;  add_header grpc-message "deadline exceeded";    return 204; }
