#!/bin/bash
set -euo pipefail

NGINX_SSL_CONF="${NGINX_SSL_CONF:-/etc/nginx/conf.d/ssl.conf}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/conf.d/sites-enabled/default.conf}"
NGINX_LOG_FORMAT_CONF="${NGINX_LOG_FORMAT_CONF:-/etc/nginx/conf.d/log-format-sentree.conf}"
PHP_FPM_CONF="${PHP_FPM_CONF:-/etc/php-fpm.conf}"
VECTOR_CONFIG="${VECTOR_CONFIG:-/etc/vector/vector.yaml}"
AXIOM_TOKEN="${AXIOM_TOKEN:-}"
BASE_URL="${BASE_URL:-}"

log() {
  echo "[sentree] $1" >> /var/log/run.log
}

comment_directive() {
  local file="$1"
  local regex="$2"
  if grep -Eq "^[[:space:]]*${regex}[[:space:]]*$" "$file" 2>/dev/null; then
    sed -i -E "/^[[:space:]]*${regex}[[:space:]]*$/ s|^([[:space:]]*)|\1# |" "$file"
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

log "Applying Sentree customizations"

comment_directive "$NGINX_SSL_CONF" "add_header[[:space:]]+alt-svc.*"
comment_directive "$NGINX_SITE_CONF" "fastcgi_cache[[:space:]]+WORDPRESS;"
comment_directive "$NGINX_SITE_CONF" "fastcgi_cache_valid[[:space:]]+200[[:space:]]+301[[:space:]]+302[[:space:]]+404[[:space:]]+12h;"
comment_directive "$NGINX_SITE_CONF" 'fastcgi_cache_bypass[[:space:]]+\$skip_cache;'
comment_directive "$NGINX_SITE_CONF" 'fastcgi_no_cache[[:space:]]+\$skip_cache;'
comment_directive "$NGINX_SITE_CONF" 'add_header[[:space:]]+X-Cache[[:space:]]+\$upstream_cache_status;'

cat <<'EOF' > "$NGINX_LOG_FORMAT_CONF"
log_format sentree_main '[$time_local] $remote_addr $upstream_response_time $upstream_cache_status $http_host "$request" $status $body_bytes_sent $request_time "$http_referer" "$http_user_agent" $http_x_sucuri_country';
EOF

if grep -Eq '^[[:space:]]*access_log[[:space:]]+.*sentree_main;' "$NGINX_SITE_CONF" 2>/dev/null; then
  :
elif grep -Eq '^[[:space:]]*access_log[[:space:]]+' "$NGINX_SITE_CONF" 2>/dev/null; then
  sed -i -E '0,/^[[:space:]]*access_log[[:space:]]+[^;]+;/{s|^[[:space:]]*access_log[[:space:]]+([^;]+);|    access_log \1 sentree_main;|}' "$NGINX_SITE_CONF"
else
  sed -i '/server_name/a\    access_log /var/log/nginx/access.log sentree_main;' "$NGINX_SITE_CONF"
fi

sed -i -E 's|^[[:space:]]*pm[[:space:]]*=.*$|pm = static|' "$PHP_FPM_CONF"

nginx -t &>> /var/log/run.log
systemctl reload nginx &>> /var/log/run.log
systemctl restart php-fpm &>> /var/log/run.log

if ! command -v vector >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSfL https://sh.vector.dev | bash -s -- -y &>> /var/log/run.log
fi

mkdir -p /etc/vector
wget -q -O "$VECTOR_CONFIG" "${BASE_URL}/vector.yaml"

if [ -n "$AXIOM_TOKEN" ]; then
  sed -i "s|\${AXIOM_TOKEN}|$(escape_sed_replacement "$AXIOM_TOKEN")|g" "$VECTOR_CONFIG"
  vector validate --no-environment "$VECTOR_CONFIG" &>> /var/log/run.log
  systemctl enable vector &>> /var/log/run.log
  systemctl restart vector &>> /var/log/run.log
else
  systemctl disable vector &>> /var/log/run.log 2>/dev/null || true
  systemctl stop vector &>> /var/log/run.log 2>/dev/null || true
  log "Skipping Vector start because Axiom settings were not provided"
fi
