#!/usr/bin/env bash
# Remnawave Node + REALITY Self-Steal SNI (Nginx on 127.0.0.1:8443)
# Target: Ubuntu/Debian + systemd. Run: sudo bash install_remnawave_selfsteal.sh
set -Eeuo pipefail
umask 077

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "Установка прервана: строка $LINENO, код завершения $?"' ERR

[[ $EUID -eq 0 ]] || die 'Запустите скрипт от root: sudo bash install_remnawave_selfsteal.sh'
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

read_value EMAIL 'Email для Lets Encrypt' 'dolbaeb@gmail.com'
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
