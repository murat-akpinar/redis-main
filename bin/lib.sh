# init.sh ve app.sh tarafından source edilen ortak fonksiyonlar.
# Çağıran proje kökünde olmalı; rcli/test_app için .env yüklenmiş olmalı.
# Not: çağıranlar "set -e" kullanır; fonksiyonlar bilinçli olarak "return 0" ile biter.

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
die()  { printf '\n[HATA] %s\n' "$*" >&2; exit 1; }

APPS_FILE=config/apps

# init.sh / app.sh aynı anda çalışıp users.acl veya config/apps'i bozmasın
acquire_lock() {
  exec 9>.lock
  flock -n 9 || die "başka bir init.sh / app.sh çalışıyor"
  return 0
}

# config/apps: satır başına bir uygulama adı, '#' sonrası yorum
apps_list() {
  [ -f "$APPS_FILE" ] || return 0
  sed -e 's/#.*//' "$APPS_FILE" | tr -s ' \t\r' '\n' | grep -v '^$' || true
}

valid_app_name() {
  case "$1" in
    admin|healthcheck|default) return 1 ;;
    ''|*[!a-z0-9_-]*)          return 1 ;;
  esac
  return 0
}

# Container içinden admin kullanıcısıyla redis-cli.
# Parola komut satırına (ps ile görünür) değil, ortam değişkeni ile aktarılır.
admin_cli() {
  REDISCLI_AUTH="$(cat secrets/admin_password)" docker compose exec -T -e REDISCLI_AUTH redis \
    redis-cli --tls --cacert /tls/ca.crt -h 127.0.0.1 --user admin --no-auth-warning "$@" 2>&1
}

# config/users.acl'i çalışan Redis'e yükler (restart gerekmez)
acl_reload() {
  _out="$(admin_cli acl load || true)"
  [ "$_out" = "OK" ] || die "ACL LOAD başarısız: $_out"
  ok "ACL yüklendi"
  return 0
}

# Kullanıcının açık bağlantılarını kapatır (parola yenileme / silme sonrası)
kill_user_clients() {
  _n=0
  for _id in $(admin_cli client list | sed -n "s/^id=\([0-9]*\) .* user=$1 .*/\1/p"); do
    admin_cli client kill id "$_id" >/dev/null || true
    _n=$((_n + 1))
  done
  [ "$_n" -eq 0 ] || ok "$1: $_n açık bağlantı kapatıldı"
  return 0
}

# Host ağından, publish edilen port üzerinden (istemcinin göreceği yol) redis-cli.
# Parola AUTH değişkeninden alınır.
rcli() {
  REDISCLI_AUTH="${AUTH:-}" docker run --rm --network host \
    -v "$PWD/tls/ca.crt:/ca.crt:ro" \
    -e REDISCLI_AUTH \
    --entrypoint redis-cli "$REDIS_IMAGE" \
    --tls --cacert /ca.crt -h "$REDIS_BIND_IP" -p "$REDIS_PUBLISHED_PORT" \
    --no-auth-warning "$@" 2>&1 || true
}

# Bir uygulama kullanıcısının bağlantısını ve yetki sınırlarını test eder.
# Başarısızlıkta global "fail" değişkenini 1 yapar.
test_app() {
  _app="$1"
  _pass="$(cat "secrets/${_app}_password")"

  _out="$(AUTH="$_pass" rcli --user "$_app" ping)"
  if [ "$_out" = "PONG" ]; then ok "$_app: TLS ile bağlandı (${REDIS_BIND_IP}:${REDIS_PUBLISHED_PORT})"
  else echo "    [FAIL] $_app PING: $_out"; fail=1; fi

  _out="$(AUTH="$_pass" rcli --user "$_app" exists "${_app}:__init_check")"
  if [ "$_out" = "0" ]; then ok "$_app: kendi prefix'ine (${_app}:*) erişebiliyor"
  else echo "    [FAIL] $_app kendi prefix'i: $_out"; fail=1; fi

  for _check in \
    "exists __baska_uygulama__:__init_check|başka prefix'e erişim engelli" \
    "scan 0|SCAN engelli (diğer uygulamaların key isimleri görünmez)" \
    "function list|FUNCTION yönetimi engelli" \
    "config get maxmemory|CONFIG engelli (@dangerous)"
  do
    _cmd="${_check%%|*}"
    _desc="${_check#*|}"
    # shellcheck disable=SC2086
    _out="$(AUTH="$_pass" rcli --user "$_app" $_cmd)"
    case "$_out" in
      *NOPERM*) ok "$_app: $_desc" ;;
      *)        echo "    [FAIL] $_app: '$_cmd' engellenmedi: $_out"; fail=1 ;;
    esac
  done
  return 0
}

# Uygulama ekibine iletilecek bağlantı bilgileri
print_app_info() {
  cat <<EOF

  Bağlantı bilgileri ($1):
    Host / Port : ${REDIS_BIND_IP}:${REDIS_PUBLISHED_PORT}  (LB arkasındaysa VIP adresi)
    TLS         : açık, CA sertifikası tls/ca.crt
    Username    : $1
    Password    : secrets/$1_password dosyasının içeriği (güvenli kanaldan iletin)
    Key prefix  : $1:   (tüm key ve pub/sub kanalları bu prefix ile başlamalı)
EOF
  return 0
}
