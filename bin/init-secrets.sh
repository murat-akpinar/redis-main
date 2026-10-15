#!/bin/sh
# Parolaları üretir (secrets/<kullanıcı>_password) ve config/users.acl'i
# config/apps listesine göre yeniden oluşturur. Doğrudan değil, init.sh / app.sh
# üzerinden çağrılır (onlar ACL'i çalışan Redis'e de yükler).
#
# - Mevcut parola dosyalarının üzerine yazmaz; yenileme için: ./app.sh rotate <isim>
# - users.acl her çalıştırmada parolalardan yeniden üretilir (yerinde yazılır,
#   bind mount inode'u korunur).
set -eu

cd "$(dirname "$0")/.."
. ./bin/lib.sh

umask 077
mkdir -p secrets

if [ ! -f "$APPS_FILE" ]; then
  {
    echo "# Redis'e bağlanan uygulamalar: satır başına bir isim."
    echo "# Elle düzenlemeyin; ./app.sh add|remove <isim> kullanın."
    # Geçiş: eski kurulumlarda parolası üretilmiş uygulamalar korunur
    for file in secrets/*_password; do
      [ -e "$file" ] || continue
      name="$(basename "$file" _password)"
      case "$name" in admin|healthcheck) ;; *) echo "$name" ;; esac
    done
  } > "$APPS_FILE"
  chmod 0644 "$APPS_FILE"
fi

REDIS_APPS="$(apps_list | tr '\n' ' ' | sed 's/ $//')"

for app in $REDIS_APPS; do
  valid_app_name "$app" \
    || die "config/apps: '$app' geçersiz (küçük harf, rakam, '-', '_'; admin/healthcheck/default olamaz)"
done

gen_password() {
  openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-48 | tr -d '\n'
}

for name in admin healthcheck $REDIS_APPS; do
  file="secrets/${name}_password"
  if [ ! -s "$file" ]; then
    gen_password > "$file"
    echo "    parola oluşturuldu: $file"
  fi
done

# Uygulama kullanıcılarının komut yetkileri.
#   -@dangerous      : FLUSHALL/FLUSHDB, KEYS, CONFIG, CLIENT LIST/KILL, INFO, MONITOR, DEBUG ...
#   -scan -randomkey : key prefix kısıtına tabi değiller; diğer uygulamaların key
#                      isimlerini (örn. session:<token>) listelemeye izin verirler
#   -pubsub          : PUBSUB CHANNELS/NUMSUB tüm uygulamaların kanal isimlerini gösterir
#                      (PUBLISH/SUBSCRIBE etkilenmez)
#   -function        : FUNCTION LOAD/FLUSH/DELETE tüm sunucuyu etkiler (FCALL serbest;
#                      fonksiyonları admin yükler)
#   -script|flush -script|kill : script cache'i ve diğer uygulamaların scriptlerini etkiler
APP_COMMANDS="+@all -@dangerous -scan -randomkey -pubsub -function -script|flush -script|kill"

hash() {
  printf '%s' "$(cat "secrets/$1_password")" | sha256sum | cut -d' ' -f1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo "user default off resetkeys resetchannels -@all"
  echo "user admin on #$(hash admin) ~* &* +@all"
  echo "user healthcheck on #$(hash healthcheck) resetkeys resetchannels -@all +ping"
  for app in $REDIS_APPS; do
    echo "user ${app} on #$(hash "$app") resetkeys resetchannels ~${app}:* &${app}:* ${APP_COMMANDS}"
  done
} > "$tmp"

if [ -f config/users.acl ] && cmp -s "$tmp" config/users.acl; then
  echo "    config/users.acl güncel"
else
  # Yerinde yaz: dosya container'a tekil bind mount edildiği için inode değişmemeli
  if [ -f config/users.acl ]; then
    cat "$tmp" > config/users.acl
  else
    cp "$tmp" config/users.acl
  fi
  echo "    config/users.acl yazıldı (uygulamalar: ${REDIS_APPS:-yok})"
fi

# Artık config/apps'te olmayan uygulamaların parola dosyaları
for file in secrets/*_password; do
  [ -e "$file" ] || continue
  name="$(basename "$file" _password)"
  case " admin healthcheck $REDIS_APPS " in
    *" $name "*) ;;
    *) echo "    [UYARI] $file kullanılmıyor (config/apps'te yok); gerekmiyorsa silin" ;;
  esac
done

exit 0
