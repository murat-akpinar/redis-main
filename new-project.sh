#!/bin/sh
# Bu dizini şablon alarak yanına (../redis-<proje>) yalıtılmış yeni bir Redis kurar:
# kendi container'ı, portu, bellek limiti, TLS'i, parolaları ve verisi olur.
#
#   ./new-project.sh <proje> [port|auto] [maxmemory_mb=1024]
#
# Port verilmezse (veya auto) 6380'den başlayarak ilk boş port seçilir.
#
# Proje adı yeni Redis'teki uygulama kullanıcısı ve key prefix'idir (<proje>:*).
# Ortam değişkeni ile verilebilir (yoksa bu dizinin .env'inden alınır):
#   REDIS_IMAGE, REDIS_BIND_IP, REDIS_TLS_EXTRA_SAN
#   TLS_DIR=<dizin>  → ca.crt, redis.crt, redis.key bu dizinden kopyalanır
# TLS_DIR yoksa ve bu dizinin tls/'inde sertifika varsa proje onu paylaşır (symlink):
# tek sertifika, tek yenileme, istemcilere tek CA. Hiçbiri yoksa proje kendi CA'sını üretir.
#   DEST=<dizin>     → ../redis-<proje> yerine başka bir dizine kurar
# Hedef dizin varsa dokunulmaz. Port/bellek sonradan: cd <dizin> && ./init.sh --port N --maxmemory MB
set -eu

cd "$(dirname "$0")"
. ./bin/lib.sh

[ $# -ge 1 ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
name="$1"
port="${2:-auto}"
mem="${3:-1024}"
dest="${DEST:-$(dirname "$PWD")/redis-$name}"

case "$name" in [a-z0-9]*) ;; *) name="" ;; esac
valid_app_name "$name" || die "proje adı: küçük harf/rakamla başlamalı; küçük harf, rakam, '-', '_'"
if [ "$port" = auto ]; then
  port=6380
  while port_used "$port"; do port=$((port + 1)); done
fi
case "$port" in ''|*[!0-9]*) die "port sayı veya auto olmalı" ;; esac
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "port 1024-65535 arası olmalı"
case "$mem" in ''|*[!0-9]*) die "maxmemory_mb sayı olmalı" ;; esac
[ "$mem" -ge 256 ] || die "maxmemory_mb en az 256"

project="${name}-redis"
limit="$(mem_limit_mb "$mem")"

[ ! -e "$dest" ] || die "$dest zaten var; üzerine yazılmaz"
# Aynı compose projesi başka dizinde varsa compose onun container'ını yeniden oluşturur
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ] \
  || die "'$project' compose projesi zaten var"
port_used "$port" && die "port $port kullanımda (dinleniyor veya bir container'a atanmış)"

check_ram "$limit"

from_env() { grep "^$1=" .env 2>/dev/null | cut -d= -f2- || true; }
image="${REDIS_IMAGE:-$(from_env REDIS_IMAGE)}"
bind_ip="${REDIS_BIND_IP:-$(from_env REDIS_BIND_IP)}"
# init.sh IP'yi terminalden sorar; terminal yoksa yarım dizin bırakmadan şimdi dur
[ -n "$bind_ip" ] || [ -t 0 ] || die "REDIS_BIND_IP belirsiz; REDIS_BIND_IP=<ip> ./new-project.sh ... ile verin"

mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
cp -R init.sh app.sh docker-compose.yml bin "$dest/"
mkdir "$dest/config" "$dest/secrets" "$dest/tls"
chmod 0700 "$dest/secrets"
cp config/redis.conf "$dest/config/"
sed -i "s/^maxmemory .*/maxmemory ${mem}mb/" "$dest/config/redis.conf"

if [ -n "${TLS_DIR:-}" ]; then
  # umask: init.sh izinleri düzeltmeden önce yarıda kalırsa redis.key herkese açık kalmasın
  (umask 077 && cp "$TLS_DIR/ca.crt" "$TLS_DIR/redis.crt" "$TLS_DIR/redis.key" "$dest/tls/")
elif [ -s tls/ca.crt ] && [ -s tls/redis.crt ] && [ -s tls/redis.key ]; then
  rmdir "$dest/tls"
  ln -s "$PWD/tls" "$dest/tls"
  ok "TLS: $PWD/tls paylaşılıyor (yenilemede tüm projeler restart edilmeli)"
fi

(
  umask 077
  sed -e "s|^REDIS_IMAGE=.*|REDIS_IMAGE=${image}|" \
      -e "s|^REDIS_BIND_IP=.*|REDIS_BIND_IP=${bind_ip}|" \
      -e "s|^REDIS_PUBLISHED_PORT=.*|REDIS_PUBLISHED_PORT=${port}|" \
      -e "s|^REDIS_MEM_LIMIT=.*|REDIS_MEM_LIMIT=${limit}m|" \
      -e "s|^REDIS_MEM_RESERVATION=.*|REDIS_MEM_RESERVATION=${mem}m|" \
      -e "s|^REDIS_TLS_CN=.*|REDIS_TLS_CN=${project}|" \
      -e "s|^REDIS_TLS_EXTRA_SAN=.*|REDIS_TLS_EXTRA_SAN=${REDIS_TLS_EXTRA_SAN:-}|" \
      .env.example > "$dest/.env"
  echo "COMPOSE_PROJECT_NAME=${project}" >> "$dest/.env"
)
ok "$dest oluşturuldu (maxmemory ${mem}mb, container ${limit}m, port ${port})"

"$dest/init.sh" && "$dest/app.sh" add "$name" \
  || die "kurulum yarım kaldı; dizin korundu. Hatayı giderip: cd $dest && ./init.sh && ./app.sh add $name"
echo
echo "  Yönetim: cd $dest && ./app.sh list|stats|rotate $name"
