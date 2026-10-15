#!/bin/sh
# Uygulama kullanıcılarını yönetir. Redis restart edilmez; diğer uygulamalar etkilenmez.
#
#   ./app.sh list               uygulamaları listeler
#   ./app.sh stats              uygulama başına bağlantı / key sayısı ve genel kaynak kullanımı
#   ./app.sh add <isim>         kullanıcı + parola oluşturur, ACL'i yükler, test eder
#   ./app.sh rotate <isim>      parolayı yeniler, eski parolayla açık bağlantıları kapatır
#   ./app.sh remove <isim>      kullanıcıyı ve parolasını siler, açık bağlantıları kapatır
#
# İsim aynı zamanda Redis username'i ve key prefix'idir (<isim>:*).
set -eu

cd "$(dirname "$0")"
. ./bin/lib.sh

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[ -f .env ] || die ".env yok; önce ./init.sh ile kurulum yapın"
set -a
. ./.env
set +a
REDIS_PUBLISHED_PORT="${REDIS_PUBLISHED_PORT:-6379}"

cmd="${1:-}"
name="${2:-}"

in_list() { apps_list | grep -qx "$1"; }

need_name() {
  [ -n "$name" ] || usage
  valid_app_name "$name" \
    || die "'$name' geçersiz: küçük harf, rakam, '-' ve '_' kullanın; admin/healthcheck/default olamaz"
}

# Değişiklik yapan komutlar (add/rotate/remove) aynı anda çalışmasın
need_lock() { acquire_lock; }

need_running() {
  [ -n "$(docker compose ps -q --status running redis 2>/dev/null)" ] \
    || die "redis container çalışmıyor; önce ./init.sh"
}

# users.acl'i yeniden üretip çalışan Redis'e yükler
apply_acl() {
  ./bin/init-secrets.sh
  acl_reload
}

run_tests() {
  fail=0
  test_app "$1"
  [ "$fail" -eq 0 ] || die "testler başarısız"
}

case "$cmd" in
  list)
    printf '%-22s  %-29s  %s\n' "USERNAME" "PAROLA DOSYASI" "KEY PREFIX"
    for app in $(apps_list); do
      printf '%-22s  %-29s  %s\n' "$app" "secrets/${app}_password" "${app}:*"
    done
    ;;

  stats)
    need_running
    info="$(admin_cli info everything | tr -d '\r')"
    field() { printf '%s\n' "$info" | sed -n "s/^$1://p"; }
    mb() { awk -v b="$1" 'BEGIN { printf "%.1fMB", b / 1048576 }'; }
    clients="$(admin_cli client list)"

    printf '%-22s  %10s  %10s\n' "USERNAME" "BAĞLANTI" "KEY"
    for app in $(apps_list); do
      conns="$(printf '%s\n' "$clients" | grep -c " user=${app} " || true)"
      # SCAN ile sayar (sunucuyu bloklamaz); çok büyük key sayısında birkaç saniye sürebilir
      keys="$(admin_cli --scan --pattern "${app}:*" --count 1000 | grep -c . || true)"
      printf '%-22s  %10s  %10s\n' "$app" "$conns" "$keys"
    done
    others="$(printf '%s\n' "$clients" | grep -c . || true)"
    printf '%-22s  %10s  %10s\n' "(toplam)" "$others" "$(admin_cli dbsize)"

    cat <<EOF

  Bellek (veri)        : $(field used_memory_human) / $(field maxmemory_human)  (policy: $(field maxmemory_policy))
  Bellek (bağlantılar) : $(mb "$(field mem_clients_normal)") / $(mb "$(admin_cli config get maxmemory-clients | tail -1)")  (maxmemory-clients)
  Silinen key (evicted): $(field evicted_keys)   (0'dan büyükse bellek yetmiyor)
  Kapatılan bağlantı   : $(field evicted_clients)   (maxmemory-clients aşımı)
  Reddedilen bağlantı  : $(field rejected_connections)   (maxclients aşımı)
  Bağlı istemci        : $(field connected_clients) / $(field maxclients)
  Komut/sn             : $(field instantaneous_ops_per_sec)
  Uptime               : $(field uptime_in_days) gün
  Sertifika bitişi     : $(openssl x509 -in tls/redis.crt -noout -enddate | cut -d= -f2)
EOF
    printf '  Container            : '
    docker stats --no-stream --format 'CPU {{.CPUPerc}}, bellek {{.MemUsage}}, PID {{.PIDs}}' "$(docker compose ps -q redis)"
    ;;

  add)
    need_name
    need_running
    need_lock
    in_list "$name" && die "'$name' zaten var (parola yenilemek için: ./app.sh rotate $name)"
    log "'$name' ekleniyor"
    [ -f "$APPS_FILE" ] || ./bin/init-secrets.sh >/dev/null
    printf '%s\n' "$name" >> "$APPS_FILE"
    apply_acl
    run_tests "$name"
    print_app_info "$name"
    ;;

  rotate)
    need_name
    need_running
    need_lock
    in_list "$name" || die "'$name' bulunamadı (./app.sh list)"
    log "'$name' parolası yenileniyor"
    rm -f "secrets/${name}_password"
    apply_acl
    kill_user_clients "$name"
    run_tests "$name"
    print_app_info "$name"
    echo
    echo "  Eski parola artık geçersiz; uygulamanın yeni parolayla yeniden yapılandırılması gerekir."
    ;;

  remove)
    need_name
    need_running
    need_lock
    in_list "$name" || die "'$name' bulunamadı (./app.sh list)"
    if [ -t 0 ]; then
      printf "'%s' kullanıcısı silinecek ve açık bağlantıları kapatılacak. Emin misiniz? [e/H] " "$name"
      read -r answer
      case "$answer" in e|E|evet|EVET) ;; *) die "iptal edildi" ;; esac
    fi
    log "'$name' siliniyor"
    tmp="$(mktemp)"
    awk -v n="$name" '{ line = $0; sub(/#.*/, "", line); gsub(/[ \t\r]/, "", line); if (line != n) print }' \
      "$APPS_FILE" > "$tmp"
    cat "$tmp" > "$APPS_FILE"
    rm -f "$tmp" "secrets/${name}_password"
    apply_acl
    kill_user_clients "$name"
    ok "'$name' silindi"
    echo
    echo "  Not: '$name:*' key'leri Redis'te kalır; TTL ile düşer veya LRU ile atılır."
    ;;

  *)
    usage
    ;;
esac
