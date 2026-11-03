#!/bin/sh
# main-redis kurulum scripti:
#   1) ön kontroller (.env, araçlar)
#   2) TLS sertifikaları (yoksa kendi CA'sı ile üretir)
#   3) parolalar + config/users.acl (bin/init-secrets.sh)
#   4) dosya sahiplik/izinleri
#   5) docker compose up (redis.conf değiştiyse restart) + healthy bekleme + ACL LOAD
#   6) doğrulama testleri
#
# Tekrar çalıştırılabilir: mevcut sertifika/parola/ACL dosyalarına dokunmaz.
#
#   ./init.sh [--port N] [--maxmemory MB]
#     --port       yayınlanan portu değiştirir (.env)
#     --maxmemory  redis.conf maxmemory + .env container limitlerini birlikte değiştirir
#   Değişiklik varsa container yeniden oluşturulur (kısa kesinti; cache boş başlar).
# Kurumsal CA sertifikası kullanılacaksa tls/ altına ca.crt, redis.crt, redis.key
# koyun; script TLS üretim adımını atlar.
set -eu

cd "$(dirname "$0")"

. ./bin/lib.sh

new_port=""
new_mem=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 için değer eksik (kullanım: ./init.sh [--port N] [--maxmemory MB])"
  case "$1" in
    --port)      new_port="$2" ;;
    --maxmemory) new_mem="$2" ;;
    *)           die "bilinmeyen argüman: $1 (kullanım: ./init.sh [--port N] [--maxmemory MB])" ;;
  esac
  shift 2
done

acquire_lock

# Root gerektiren işlemler (chown/chmod 999:999):
# root ise doğrudan, şifresiz sudo varsa sudo ile, yoksa docker grubu üzerinden
# redis image'ı içinde root olarak çalıştırılır.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    cmd="$1"
    shift
    # Aynı yollarla mount: tls/ başka projeye symlink olsa da container içinde çözülür
    docker run --rm --user 0:0 --network none -v "$PWD:$PWD" -w "$PWD" \
      -v "$(readlink -f tls):$(readlink -f tls)" \
      --entrypoint "$cmd" "$REDIS_IMAGE" "$@"
  fi
}

################################################################################
log "1/6 Ön kontroller"
################################################################################
for cmd in docker openssl sha256sum ip flock; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' bulunamadı"
done
docker compose version >/dev/null 2>&1 || die "docker compose plugin bulunamadı"

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 0600 .env
  ok ".env, .env.example'dan oluşturuldu"
fi

# .env içinde KEY=VALUE satırını günceller, yoksa ekler
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}

set -a
. ./.env
set +a

# --- Sonradan port / bellek değişikliği (değişkenler set -a ile export edildiği için
# yeniden atama compose'a da geçer)
if [ -n "$new_port" ]; then
  case "$new_port" in ''|*[!0-9]*) die "--port sayı olmalı" ;; esac
  [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ] || die "--port 1024-65535 arası olmalı"
  if [ "$new_port" != "${REDIS_PUBLISHED_PORT:-6379}" ]; then
    port_used "$new_port" && die "port $new_port kullanımda (dinleniyor veya bir container'a atanmış)"
    set_env REDIS_PUBLISHED_PORT "$new_port"
    REDIS_PUBLISHED_PORT="$new_port"
    ok "port ${new_port} olarak ayarlandı (istemcileri ve firewall kuralını güncelleyin)"
  fi
fi
if [ -n "$new_mem" ]; then
  case "$new_mem" in ''|*[!0-9]*) die "--maxmemory sayı (MB) olmalı" ;; esac
  [ "$new_mem" -ge 256 ] || die "--maxmemory en az 256"
  new_limit="$(mem_limit_mb "$new_mem")"
fi
# Aynı değer tekrar yazılmasın: redis.conf'un mtime'ı değişirse container gereksiz restart olur
if [ -n "$new_mem" ] && ! { grep -qx "maxmemory ${new_mem}mb" config/redis.conf \
     && [ "${REDIS_MEM_LIMIT:-}" = "${new_limit}m" ]; }; then
  check_ram "$new_limit" "$(docker compose ps -aq --no-trunc redis 2>/dev/null || true)"
  sed -i "s/^maxmemory .*/maxmemory ${new_mem}mb/" config/redis.conf
  set_env REDIS_MEM_LIMIT "${new_limit}m"
  set_env REDIS_MEM_RESERVATION "${new_mem}m"
  REDIS_MEM_LIMIT="${new_limit}m"
  REDIS_MEM_RESERVATION="${new_mem}m"
  ok "maxmemory ${new_mem}mb, container limiti ${new_limit}m olarak ayarlandı"
fi

# --- REDIS_IMAGE: boşsa REDIS_VERSION etiketini çekip digest ile sabitler
if [ -z "${REDIS_IMAGE:-}" ]; then
  : "${REDIS_VERSION:?.env içinde REDIS_IMAGE veya REDIS_VERSION tanımlı olmalı}"
  echo "    redis:${REDIS_VERSION} çekiliyor..."
  docker pull -q "redis:${REDIS_VERSION}" >/dev/null || die "redis:${REDIS_VERSION} çekilemedi"
  digest="$(docker inspect --format '{{index .RepoDigests 0}}' "redis:${REDIS_VERSION}" | sed 's/.*@//')"
  REDIS_IMAGE="redis:${REDIS_VERSION}@${digest}"
  set_env REDIS_IMAGE "$REDIS_IMAGE"
  ok "REDIS_IMAGE .env'e yazıldı: ${REDIS_IMAGE}"
fi

# --- REDIS_BIND_IP: boşsa host'un IP adreslerinden seçilir
if [ -z "${REDIS_BIND_IP:-}" ]; then
  candidates="$(ip -o -4 addr show scope global \
    | awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|cali|vxlan|tun|wg)/ {split($4, a, "/"); print a[1]}')"
  default_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
  count="$(printf '%s\n' "$candidates" | grep -c . || true)"

  [ "$count" -gt 0 ] || die "host üzerinde uygun IP bulunamadı; .env içinde REDIS_BIND_IP'yi elle girin"

  if [ "$count" -eq 1 ]; then
    REDIS_BIND_IP="$candidates"
  elif [ -t 0 ]; then
    echo "    Redis'in dinleyeceği IP adresini seçin:"
    n=1
    for addr in $candidates; do
      mark=""; [ "$addr" = "$default_ip" ] && mark=" (varsayılan route)"
      echo "      $n) $addr$mark"
      n=$((n + 1))
    done
    printf '    Seçim [IP veya numara]: '
    read -r choice
    case "$choice" in
      ''|*[!0-9]*) REDIS_BIND_IP="$choice" ;;
      *)           REDIS_BIND_IP="$(printf '%s\n' "$candidates" | sed -n "${choice}p")" ;;
    esac
    [ -n "$REDIS_BIND_IP" ] || die "geçersiz seçim"
  else
    die "birden fazla IP var ($(echo $candidates)); .env içinde REDIS_BIND_IP'yi elle girin"
  fi

  set_env REDIS_BIND_IP "$REDIS_BIND_IP"
  ok "REDIS_BIND_IP .env'e yazıldı: ${REDIS_BIND_IP}"
fi

case "$REDIS_BIND_IP" in
  0.0.0.0|::) die "REDIS_BIND_IP tüm arayüzler olamaz; belirli bir IP girin" ;;
esac

REDIS_PUBLISHED_PORT="${REDIS_PUBLISHED_PORT:-6379}"
REDIS_TLS_CN="${REDIS_TLS_CN:-main-redis}"
REDIS_TLS_EXTRA_SAN="${REDIS_TLS_EXTRA_SAN:-}"
REDIS_TLS_DAYS="${REDIS_TLS_DAYS:-825}"
REDIS_CA_DAYS="${REDIS_CA_DAYS:-3650}"

case "$REDIS_IMAGE" in
  *REPLACE*)   die "REDIS_IMAGE içinde gerçek digest yok (.env)" ;;
  *@sha256:*)  ok "image digest ile sabitlenmiş" ;;
  *)           die "REDIS_IMAGE digest ile sabitlenmeli (image@sha256:...)" ;;
esac

ip -o addr show 2>/dev/null | grep -q " ${REDIS_BIND_IP}/" \
  || die "REDIS_BIND_IP=${REDIS_BIND_IP} bu host'ta tanımlı değil"
ok "bind IP host üzerinde mevcut"

docker compose config -q || die "docker-compose.yml geçersiz"
ok "compose config geçerli"

# Container 999:999 ile çalışır; host'ta bu uid/gid'e sahip kullanıcı/grup
# redis.key, healthcheck parolası ve users.acl'i okuyabilir
host999="$(getent passwd 999 | cut -d: -f1) $(getent group 999 | cut -d: -f1)"
if [ -n "${host999# }" ]; then
  echo "    [UYARI] host'ta uid/gid 999 kullanımda (${host999# }): bu kullanıcı/grubun üyeleri"
  echo "            TLS anahtarını ve healthcheck parolasını okuyabilir"
else
  ok "uid/gid 999 host'ta kullanılmıyor"
fi

if [ "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo 1)" != "1" ]; then
  echo "    [UYARI] vm.overcommit_memory=1 değil; yük altında BGSAVE/AOF rewrite başarısız olabilir. Düzeltmek için:"
  echo "            echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-redis.conf && sudo sysctl --system"
else
  ok "vm.overcommit_memory=1"
fi

################################################################################
log "2/6 TLS sertifikaları"
################################################################################
mkdir -p tls
chmod 0755 tls

if [ -s tls/ca.crt ] && [ -s tls/redis.crt ] && [ -s tls/redis.key ]; then
  ok "tls/ altında sertifikalar mevcut, üretim atlandı"
elif [ -L tls ]; then
  # Paylaşılan TLS'e üretim yapılırsa tüm projelerin CA'sı değişir
  die "paylaşılan TLS ($(readlink -f tls)) eksik; sertifikayı orada yenileyip tekrar çalıştırın"
else
  # pki/ yalnızca sertifikayı biz üretiyorsak oluşur (kurumsal/paylaşılan TLS'te gerekmez)
  mkdir -p pki
  chmod 0700 pki
  (
    umask 077

    if [ ! -s pki/ca.key ] || [ ! -s tls/ca.crt ]; then
      cat > pki/ca.cnf <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = ${REDIS_TLS_CN} CA
[v3_ca]
basicConstraints     = critical,CA:TRUE
keyUsage             = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
      openssl genrsa -out pki/ca.key 4096 2>/dev/null
      openssl req -x509 -new -key pki/ca.key -sha256 -days "$REDIS_CA_DAYS" \
        -config pki/ca.cnf -extensions v3_ca -out tls/ca.crt
      echo "    CA oluşturuldu (anahtar: pki/ca.key — container'a mount EDİLMEZ)"
    fi

    SAN="DNS:localhost,IP:127.0.0.1,IP:${REDIS_BIND_IP}"
    [ -n "$REDIS_TLS_EXTRA_SAN" ] && SAN="${SAN},${REDIS_TLS_EXTRA_SAN}"

    cat > pki/redis.ext <<EOF
basicConstraints       = CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
subjectAltName         = ${SAN}
EOF

    openssl genrsa -out tls/redis.key 2048 2>/dev/null
    openssl req -new -key tls/redis.key -subj "/CN=${REDIS_TLS_CN}" -out pki/redis.csr
    openssl x509 -req -in pki/redis.csr -CA tls/ca.crt -CAkey pki/ca.key \
      -CAserial pki/ca.srl -CAcreateserial \
      -days "$REDIS_TLS_DAYS" -sha256 -extfile pki/redis.ext -out tls/redis.crt 2>/dev/null
    echo "    sunucu sertifikası oluşturuldu, SAN: ${SAN}"
  )
fi

# eski sürümlerden kalan serial dosyası container'a mount edilmesin
[ -f tls/ca.srl ] && mkdir -p pki && mv tls/ca.srl pki/ca.srl

openssl verify -CAfile tls/ca.crt tls/redis.crt >/dev/null || die "redis.crt, ca.crt ile doğrulanamadı"
ok "sertifika zinciri doğrulandı"

if openssl x509 -in tls/redis.crt -noout -checkip "$REDIS_BIND_IP" 2>/dev/null | grep -q 'does match'; then
  ok "sertifika ${REDIS_BIND_IP} adresini içeriyor"
elif [ -s pki/ca.key ]; then
  die "redis.crt, REDIS_BIND_IP=${REDIS_BIND_IP} adresini içermiyor (IP değişmiş olabilir). Yenilemek için tls/redis.crt ve tls/redis.key silip tekrar çalıştırın."
else
  # Kurumsal sertifika (ör. yalnızca DNS adı / LB adı): istemciler bu adla bağlanır
  ok "kurumsal sertifika, IP içermiyor; istemciler şu adlardan biriyle bağlanmalı: $(openssl x509 -in tls/redis.crt -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')"
fi

if openssl x509 -in tls/redis.crt -noout -checkend 2592000 >/dev/null; then
  ok "sertifika geçerlilik sonu: $(openssl x509 -in tls/redis.crt -noout -enddate | cut -d= -f2)"
else
  echo "    [UYARI] redis.crt 30 gün içinde sona eriyor; README → Sertifika yenileme"
fi

################################################################################
log "3/6 Parolalar ve ACL"
################################################################################
# Önceki kurulumda 999:999 0400 yapılmış dosyaları tekrar okunabilir/yazılabilir yap
for f in config/users.acl secrets/healthcheck_password; do
  [ -e "$f" ] && [ ! -w "$f" ] && as_root chown "$(id -u):999" "$f" && as_root chmod 0640 "$f"
done

./bin/init-secrets.sh
[ -s config/users.acl ] || die "config/users.acl oluşturulamadı"
REDIS_APPS="$(apps_list | tr '\n' ' ' | sed 's/ $//')"
ok "parolalar ve users.acl hazır"

################################################################################
log "4/6 Sahiplik ve izinler"
################################################################################
# Sahibi kurulum kullanıcısı (tekrar çalıştırmada okuyup güncelleyebilsin),
# grup 999 (container yalnızca okur)
as_root chown "$(id -u):999" config/users.acl secrets/healthcheck_password tls/redis.key
as_root chmod 0640 config/users.acl
as_root chmod 0440 secrets/healthcheck_password tls/redis.key
chmod 0444 tls/redis.crt tls/ca.crt
chmod 0755 bin/healthcheck.sh
ok "izinler ayarlandı"

################################################################################
log "5/6 Container başlatılıyor"
################################################################################
docker compose up -d

cid="$(docker compose ps -q redis)"
[ -n "$cid" ] || die "redis container bulunamadı"

# redis.conf container başladıktan sonra değiştiyse yeni ayarlar için restart gerekir
started="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$cid")" +%s)"
if [ "$(stat -c %Y config/redis.conf)" -gt "$started" ]; then
  echo "    config/redis.conf değişmiş, container yeniden başlatılıyor"
  docker compose restart redis
fi

printf '    healthy bekleniyor'
status=""
i=0
while [ $i -lt 30 ]; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")"
  [ "$status" = "healthy" ] && break
  if [ "$status" = "unhealthy" ] || [ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]; then
    break
  fi
  printf '.'
  sleep 3
  i=$((i + 1))
done
echo

if [ "$status" != "healthy" ]; then
  docker compose logs --tail 50 redis >&2
  die "container healthy olmadı (durum: ${status:-bilinmiyor})"
fi
ok "container healthy"

# users.acl değişmişse çalışan Redis'e yükle (restart gerekmez)
acl_reload

################################################################################
log "6/6 Doğrulama testleri"
################################################################################
fail=0

out="$(docker compose exec -T redis /usr/local/bin/redis-healthcheck 2>&1 && echo OK || true)"
if [ "$out" = "OK" ]; then ok "container içi healthcheck"; else echo "    [FAIL] container içi healthcheck: $out"; fail=1; fi

for app in $REDIS_APPS; do
  test_app "$app"
done

out="$(AUTH="" rcli ping)"
case "$out" in
  *NOAUTH*) ok "kimliksiz bağlantı reddedildi (default kullanıcı kapalı)" ;;
  *)        echo "    [FAIL] kimliksiz PING beklenmeyen yanıt: $out"; fail=1 ;;
esac

out="$(docker run --rm --network host --entrypoint redis-cli "$REDIS_IMAGE" \
  -h "$REDIS_BIND_IP" -p "$REDIS_PUBLISHED_PORT" ping 2>&1 || true)"
case "$out" in
  PONG|*NOAUTH*) echo "    [FAIL] plaintext bağlantı kabul edildi: $out"; fail=1 ;;
  *)             ok "plaintext (TLS'siz) bağlantı reddedildi" ;;
esac

echo
if [ "$fail" -ne 0 ]; then
  die "bazı testler başarısız"
fi

cat <<EOF
Kurulum tamamlandı.

  Adres : ${REDIS_BIND_IP}:${REDIS_PUBLISHED_PORT} (TLS)
  CA    : tls/ca.crt  (istemcilere dağıtın)
EOF
echo
./app.sh list | sed 's/^/  /'
echo
echo "  Uygulama eklemek / silmek / parola yenilemek: ./app.sh add|remove|rotate <isim>"
