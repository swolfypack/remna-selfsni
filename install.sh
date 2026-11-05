#!/usr/bin/env bash
# Remnawave Node + REALITY Self-Steal SNI (Nginx on 127.0.0.1:8443)
# Target: Ubuntu/Debian + systemd. Supports: bash <(curl -fsSL https://raw.githubusercontent.com/radmir42/remna-selfsni/main/install.sh)
set -Eeuo pipefail
umask 077

# The complete function, including here-documents, is parsed before installation begins.
# This prevents a truncated GitHub response from running half an installer.
main() {
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "Установка прервана: строка $LINENO, код завершения $?"' ERR

[[ $EUID -eq 0 ]] || die 'Запустите установщик от root.'
command -v apt-get >/dev/null || die 'Поддерживаются только Debian/Ubuntu (apt-get).'
command -v systemctl >/dev/null || die 'Необходим systemd.'

INSTALL_DIR='/opt/remnanode'
ACME='/root/.acme.sh/acme.sh'
CERT_DIR='/root/certs'
NGINX_SITE='/etc/nginx/sites-available/remnawave-selfsteal.conf'
NGINX_ENABLED='/etc/nginx/sites-enabled/remnawave-selfsteal.conf'
HTML_FILE='/var/www/html/index.nginx-debian.html'
SYSCTL_FILE='/etc/sysctl.d/99-remnanode-tuning.conf'
BACKUP_SUFFIX="bak.$(date +%Y%m%d-%H%M%S)"

backup_file() {
  if [[ -e "$1" || -L "$1" ]]; then
    cp -a -- "$1" "${1}.${BACKUP_SUFFIX}"
    info "Резервная копия: ${1}.${BACKUP_SUFFIX}"
  fi
}

port_listening() {
  ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q .
}

read_value() {
  local name="$1" prompt="$2" fallback="$3" answer
  if [[ -z ${!name:-} ]]; then
    read -r -p "$prompt [$fallback]: " answer
    printf -v "$name" '%s' "${answer:-$fallback}"
  fi
}

info 'Установка Remnawave Node + Self-Steal SNI'
read_value DOMAIN 'Домен Self-Steal SNI (A-запись указывает на этот сервер)' ''
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die 'Укажите корректный домен, например: node.example.com'

EMAIL='dolbaeb@gmail.com' # acme.sh / Let's Encrypt: без интерактивного запроса
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Некорректный email.'

read_value NODE_PORT 'Порт управления Remnawave Node' '2222'
[[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die 'NODE_PORT должен быть числом.'
(( 10#$NODE_PORT >= 1 && 10#$NODE_PORT <= 65535 )) || die 'NODE_PORT вне диапазона 1..65535.'
NODE_PORT="$((10#$NODE_PORT))"
[[ "$NODE_PORT" != 80 && "$NODE_PORT" != 443 && "$NODE_PORT" != 8443 ]] || die 'NODE_PORT не должен совпадать с 80, 443 или 8443.'

if [[ -z ${SECRET_KEY:-} ]]; then
  read -r -s -p 'SECRET_KEY из Remnawave Panel (скрытый ввод): ' SECRET_KEY
  printf '\n'
fi
[[ -n "$SECRET_KEY" ]] || die 'SECRET_KEY не может быть пустым.'
# Keep .env and Compose interpolation unambiguous; Remnawave's key is base64-safe.
[[ "$SECRET_KEY" =~ ^[a-zA-Z0-9._+/=-]+$ ]] || die 'SECRET_KEY содержит необычные символы: используйте ключ, скопированный из панели (base64).'

if port_listening 80; then
  ss -ltnp '( sport = :80 )' || true
  die 'Порт 80 занят. Для выпуска и продления сертификата в standalone-режиме он должен быть свободен.'
fi
if port_listening 8443 && [[ ! -e "$NGINX_SITE" ]]; then
  ss -ltnp '( sport = :8443 )' || true
  die 'Порт 8443 уже занят другим сервисом.'
fi
if port_listening "$NODE_PORT" && [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
  ss -ltnp "( sport = :$NODE_PORT )" || true
  die "Порт NODE_PORT=$NODE_PORT уже занят."
fi

if ! getent ahostsv4 "$DOMAIN" >/dev/null; then
  warn "Домен $DOMAIN пока не разрешается в IPv4. ACME может не пройти до настройки DNS."
fi
info 'Для выдачи сертификата нужен доступ из интернета к TCP/80 без проксирования через CDN.'

info '[1/6] Базовые пакеты и Docker'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git cron socat openssl iproute2 kmod logrotate
systemctl enable --now cron

if ! command -v docker >/dev/null 2>&1; then
  tmp_docker="$(mktemp)"
  curl -fsSL --connect-timeout 15 --max-time 120 https://get.docker.com -o "$tmp_docker"
  sh "$tmp_docker"
  rm -f "$tmp_docker"
fi
systemctl enable --now docker
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin || die 'Docker Compose plugin не установлен. Установите docker-compose-plugin.'
fi

info '[2/6] Установка acme.sh (через GitHub) и получение сертификата'
if [[ ! -x "$ACME" ]]; then
  tmp_acme_dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp_acme_dir/acme.sh"
  # IMPORTANT: acme.sh --install uses ./acme.sh relative to the current directory.
  (
    cd "$tmp_acme_dir/acme.sh"
    ./acme.sh --install --home /root/.acme.sh -m "$EMAIL"
  )
  [[ -x "$ACME" ]] || die "acme.sh installation did not create $ACME"
  rm -rf "$tmp_acme_dir"
fi
"$ACME" --set-default-ca --server letsencrypt
if ! "$ACME" --issue --server letsencrypt --standalone -d "$DOMAIN" --keylength ec-256; then
  warn 'Выпуск пропущен или завершился ошибкой; проверяем, есть ли действующий ранее выпущенный сертификат.'
  "$ACME" --info -d "$DOMAIN" >/dev/null || die 'Нет сертификата в acme.sh. Проверьте DNS и TCP/80.'
fi

info '[3/6] Nginx с TLS-сайтом на 127.0.0.1:8443'
apt-get install -y nginx-full
install -d -m 700 "$CERT_DIR"
# Cert files installed by acme.sh, not direct symlinks into its internal storage.
touch "$CERT_DIR/key.pem" "$CERT_DIR/fullchain.pem"
chmod 600 "$CERT_DIR/key.pem" "$CERT_DIR/fullchain.pem"

install -d -m 755 /var/www/html
backup_file "$HTML_FILE"
cat > "$HTML_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="robots" content="noindex, nofollow">
    <title>CloudNode — Infrastructure Services</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            min-height: 100vh; display: flex; align-items: center;
            justify-content: center; background: #f7f8fa; color: #1f2937;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                         Helvetica, Arial, sans-serif;
        }
        .container { width: 100%; max-width: 620px; padding: 40px; text-align: center; }
        .logo {
            width: 64px; height: 64px; margin: 0 auto 24px;
            display: flex; align-items: center; justify-content: center;
            border-radius: 16px; background: #111827;
            color: #ffffff; font-size: 28px; font-weight: 700;
        }
        h1 { font-size: 32px; font-weight: 600; margin-bottom: 12px; }
        .description { color: #6b7280; font-size: 16px; line-height: 1.6; margin-bottom: 30px; }
        .status {
            display: inline-flex; align-items: center; gap: 10px; padding: 12px 18px;
            background: #ffffff; border: 1px solid #e5e7eb;
            border-radius: 10px; font-size: 14px;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.04);
        }
        .status-dot {
            width: 9px; height: 9px; border-radius: 50%; background: #22c55e;
            box-shadow: 0 0 0 4px rgba(34, 197, 94, 0.12);
        }
        footer { margin-top: 40px; color: #9ca3af; font-size: 13px; }
    </style>
</head>
<body>
<div class="container">
    <div class="logo">C</div>
    <h1>CloudNode</h1>
    <p class="description">
        Infrastructure and network services.<br>
        This node is operating normally.
    </p>
    <div class="status"><span class="status-dot"></span>
        <span>All systems operational</span></div>
    <footer>CloudNode Infrastructure</footer>
</div>
</body>
</html>
HTML
chmod 644 "$HTML_FILE"

backup_file "$NGINX_SITE"
cat > "$NGINX_SITE" <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    root /var/www/html;
    index index.nginx-debian.html;

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SELFSTEAL_SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    keepalive_timeout 30s;
    client_header_timeout 15s;
    client_body_timeout 15s;
    send_timeout 30s;
    access_log off;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sfn "$NGINX_SITE" "$NGINX_ENABLED"

# The packaged default site would otherwise occupy TCP/80 and break renewal.
if [[ -L /etc/nginx/sites-enabled/default && "$(readlink /etc/nginx/sites-enabled/default)" == '/etc/nginx/sites-available/default' ]]; then
  rm /etc/nginx/sites-enabled/default
  info 'Стандартный сайт Nginx отключен (освобождён TCP/80).'
fi

if [[ -f /etc/nginx/nginx.conf ]]; then
  backup_file /etc/nginx/nginx.conf
  sed -i -E 's/^[[:space:]]*worker_connections[[:space:]]+[0-9]+;/    worker_connections 8192;/' /etc/nginx/nginx.conf
  if ! grep -Eq '^worker_rlimit_nofile[[:space:]]' /etc/nginx/nginx.conf; then
    sed -i '1i worker_rlimit_nofile 262144;' /etc/nginx/nginx.conf
  fi
fi
install -d -m 755 /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/90-remnawave-limits.conf <<'EOF'
[Service]
LimitNOFILE=262144
EOF
systemctl daemon-reload

# A safe reload hook: during first installation nginx might be stopped,
# but all subsequent renewals reload the active service after nginx -t.
cat > /usr/local/sbin/remnawave-reload-nginx <<'RELOAD'
#!/bin/sh
/usr/sbin/nginx -t || exit 1
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    echo 'Nginx is inactive; will start it after the certificate is installed.'
fi
RELOAD
chmod 755 /usr/local/sbin/remnawave-reload-nginx
# Also persists the hook for automatic renewals.
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd '/usr/local/sbin/remnawave-reload-nginx'
nginx -t
systemctl enable --now nginx
systemctl reload nginx

if port_listening 80; then
  warn 'После запуска Nginx TCP/80 занят! Продление standalone-сертификата может не сработать.'
  ss -ltnp '( sport = :80 )' || true
fi
if ! port_listening 8443; then
  die 'Nginx не слушает 127.0.0.1:8443: проверьте journalctl -u nginx.'
fi

info '[4/6] Remnawave Node в host network'
install -d -m 700 "$INSTALL_DIR"
backup_file "$INSTALL_DIR/.env"
backup_file "$INSTALL_DIR/docker-compose.yml"
printf 'NODE_PORT=%s\nSECRET_KEY=%s\n' "$NODE_PORT" "$SECRET_KEY" > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"
unset SECRET_KEY
cat > "$INSTALL_DIR/docker-compose.yml" <<'YAML'
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: ${NODE_PORT}
      SECRET_KEY: ${SECRET_KEY}
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
YAML
chmod 644 "$INSTALL_DIR/docker-compose.yml"
(
  cd "$INSTALL_DIR"
  docker compose config --quiet
  docker compose pull
  docker compose up -d
)

info '[5/6] Настройки Linux для высокой нагрузки'
backup_file "$SYSCTL_FILE"
cat > "$SYSCTL_FILE" <<'EOF'
# Remnawave/Xray tuning. Do not forcibly disable IPv6 or change firewall rules.
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
vm.swappiness = 10
EOF

# Use BBR only when supported by the current kernel.
modprobe tcp_bbr >/dev/null 2>&1 || true
modprobe sch_fq >/dev/null 2>&1 || true
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' >> "$SYSCTL_FILE"
else
  warn 'BBR не поддерживается этим ядром: оставляем текущий алгоритм.'
fi
if ! sysctl -p "$SYSCTL_FILE"; then
  warn "Не все sysctl применились. Проверьте $SYSCTL_FILE и ограничения VPS."
fi

info '[6/6] Проверка установки'
if ! curl --noproxy '*' -fsSI --connect-timeout 5 --max-time 10 \
    --resolve "$DOMAIN:8443:127.0.0.1" "https://$DOMAIN:8443/" >/dev/null; then
  warn 'Локальная HTTPS-проверка не прошла. Проверьте nginx -t и curl -v --resolve.'
else
  info 'Локальный HTTPS-сайт Self-Steal отвечает с корректным TLS.'
fi
(
  cd "$INSTALL_DIR"
  docker compose ps
)

printf '\n===========================================================\n'
printf 'Установка выполнена.\n'
printf 'Домен/SNI:              %s\n' "$DOMAIN"
printf 'REALITY target:          127.0.0.1:8443\n'
printf 'REALITY xver:            0\n'
printf 'Remnawave NODE_PORT:    %s (доступ только с IP панели!)\n' "$NODE_PORT"
printf 'Нода:                   %s\n' "$INSTALL_DIR"
printf 'SSL:                    %s\n' "$CERT_DIR"
printf 'Nginx:                  %s\n' "$NGINX_SITE"
printf 'Tuning:                 %s\n' "$SYSCTL_FILE"
printf '===========================================================\n'
printf 'Далее: в профиле REALITY панели укажите target, xver и serverNames\n'
printf 'с этим доменом, а в Hosts выставьте SNI = %s.\n' "$DOMAIN"
printf 'TCP/80 нужен для LE; TCP/443 нужен для Xray; NODE_PORT разрешить только IP панели.\n'
printf 'Скрипт НЕ открывает UFW и НЕ настраивает REALITY в панели.\n'
printf '\nПроверка: ss -ltnp | grep -E ":(80|443|8443|%s)\\b"\n' "$NODE_PORT"
printf 'Логи ноды: cd %s && docker compose logs -f --tail=100\n' "$INSTALL_DIR"

# END_OF_REMNAWAVE_SELFSTEAL_INSTALLER_V5

}

main "$@"
