# main-redis

TLS-only, ACL korumalı, read-only container olarak çalışan production Redis (standalone, cache).

- Yalnızca TLS ile bağlanılır; plaintext port kapalı.
- `default` kullanıcı kapalı. Her uygulama kendi kullanıcısı ve parolasıyla bağlanır, yalnızca kendi key prefix'ine erişir.
- Container root olmayan kullanıcıyla (999), `read_only`, `cap_drop: ALL`, `no-new-privileges` ile çalışır.
- Kurulum ve uygulama yönetimi iki script ile yapılır: `init.sh` ve `app.sh`.

## Dizin yapısı

```
.
├── init.sh                 → kurulum: TLS, parolalar, izinler, compose up, testler
├── app.sh                  → uygulama kullanıcıları: add / remove / rotate / list
├── docker-compose.yml
├── .env.example            → init.sh ilk çalıştırmada .env'i buradan oluşturur
├── bin/
│   ├── healthcheck.sh      → container içinde TLS + ACL ile PING (compose healthcheck)
│   ├── init-secrets.sh     → parolalar + users.acl üretir (init.sh / app.sh çağırır)
│   └── lib.sh              → ortak fonksiyonlar
├── config/
│   ├── redis.conf
│   ├── apps                → uygulama listesi (app.sh yönetir, git'e girebilir)
│   ├── users.acl           → üretilir, elle düzenlenmez (git dışı)
│   └── users.acl.example   → örnek ACL formatı
├── secrets/                → <kullanıcı>_password dosyaları (git dışı)
├── tls/                    → ca.crt, redis.crt, redis.key (git dışı, container'a mount edilir)
├── pki/                    → CA anahtarı (git dışı, container'a mount EDİLMEZ)
└── data/                   → AOF/RDB (git dışı)
```

## Gereksinimler

- Docker Engine + Docker Compose v2 plugin
- `openssl`, `sha256sum`, `ip` (iproute2), `flock` (util-linux)
- Script'i çalıştıran kullanıcı `docker` grubunda olmalı (veya root).
  Dosya sahipliği için sudo gerekmez; şifresiz sudo yoksa docker üzerinden yapılır.
- Önerilen host ayarı (yoksa `init.sh` uyarır):

  ```sh
  echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-redis.conf && sudo sysctl --system
  ```

## Kurulum

```sh
./init.sh                    # kurulum
./app.sh add siparis         # uygulama kullanıcıları
./app.sh add uyelik
./app.sh add rapor
```

Hiçbir dosyayı düzenlemeye gerek yoktur. `init.sh` sırasıyla:

1. **Ön kontroller ve `.env`**
   - `.env` yoksa `.env.example`'dan oluşturur
   - `REDIS_IMAGE` boşsa `REDIS_VERSION` etiketini çeker, digest ile sabitleyip `.env`'e yazar
   - `REDIS_BIND_IP` boşsa sunucunun IP'lerini bulur (docker/bridge/VPN arayüzleri hariç);
     tek IP varsa onu kullanır, birden fazlaysa listeleyip sorar ve `.env`'e yazar
   - IP'nin host'ta tanımlı olduğunu, compose dosyasını ve `vm.overcommit_memory`'yi kontrol eder
2. **TLS:** `tls/` boşsa kendi CA'sını ve sunucu sertifikasını üretir
3. **Parolalar ve ACL:** `admin`, `healthcheck` ve `config/apps`'teki uygulamalar için parola üretir, `config/users.acl`'i yazar
4. **İzinler:** `data/` 999:999 0700; `users.acl`, `healthcheck_password`, `redis.key` kurulum kullanıcısı:999 (container yalnızca okur)
5. **Başlatma:** `docker compose up -d`, `healthy` bekleme (en fazla ~90 sn), `ACL LOAD`
6. **Testler:**
   - container içi healthcheck
   - her uygulama için: TLS ile PING, kendi prefix'ine erişim; başka prefix'e, `SCAN`, `FUNCTION` ve `CONFIG`'e erişimin engellenmesi
   - kimliksiz bağlantının ve TLS'siz bağlantının reddedilmesi

`init.sh` tekrar çalıştırılabilir: mevcut `.env`, sertifika ve parolalara dokunmaz, yalnızca eksikleri tamamlar.
`config/redis.conf` değiştirildiyse container'ı kendisi yeniden başlatır. `init.sh` ve `app.sh`
aynı anda çalıştırılamaz (kilit).

Kurulumdan sonra **firewall kuralını** ekleyin (bkz. "Firewall").

### LB / DNS adı ile kurulum

İstemciler Redis'e IP yerine bir DNS adı veya LB VIP'i ile bağlanacaksa, bu adresler sertifikada
bulunmalıdır. İlk çalıştırmadan **önce**:

```sh
cp .env.example .env
# .env: REDIS_TLS_EXTRA_SAN=DNS:redis.kurum.local,IP:<VIP>
./init.sh
```

### Kurumsal CA sertifikası ile kurulum

`init.sh`'ten önce dosyaları `tls/` altına koyun; sertifika üretimi atlanır:

```
tls/ca.crt      → sertifikayı imzalayan CA (zincir)
tls/redis.crt   → SAN listesinde sunucu IP'si / DNS adı olmalı
tls/redis.key
```

## Uygulama kullanıcıları

Her uygulama ayrı bir ACL kullanıcısıyla bağlanır ve yalnızca kendi key prefix'ine erişir.
Redis restart edilmez, diğer uygulamalar etkilenmez:

```sh
./app.sh add siparis       # kullanıcı + parola oluşturur, ACL'i yükler, test eder, bağlantı bilgisini basar
./app.sh list              # uygulamaları listeler
./app.sh stats             # uygulama başına bağlantı / key sayısı, bellek, eviction, CPU
./app.sh rotate siparis    # parolayı yeniler, eski parolalı bağlantıları kapatır
./app.sh remove siparis    # kullanıcıyı ve parolasını siler, bağlantıları kapatır
```

- İsim: küçük harf, rakam, `-`, `_`. `admin`, `healthcheck`, `default` kullanılamaz.
- Liste `config/apps` dosyasında tutulur (gizli bilgi içermez). Sunucu yeniden kurulduğunda
  `./init.sh` bu listeye göre kullanıcıları oluşturur.
- `.env`, `docker-compose.yml` veya `redis.conf` değiştirilmez.

### Uygulama ekibine verilecek bilgiler

`./app.sh add` bunları ekrana basar:

| Ayar | Değer |
|---|---|
| Host / port | `REDIS_BIND_IP` (veya LB VIP / DNS adı) : `6379` |
| TLS | açık; sunucu sertifikası `tls/ca.crt` ile doğrulanır |
| Username | uygulama adı, örn. `siparis` |
| Password | `secrets/siparis_password` dosyasının içeriği (güvenli kanal/vault ile iletin) |
| Key prefix | `siparis:` — tüm key'ler bu prefix ile yazılmalı (örn. `siparis:sepet:42`) |
| Pub/Sub kanalları | `siparis:*` |
| Database | `0` |

### Uygulamalar için kurallar

- Prefix dışındaki key'lere erişim `NOPERM` hatası verir. Çoğu kütüphanede prefix ayarı vardır
  (Spring Data Redis `prefix`, StackExchange.Redis `WithKeyPrefix`, ioredis `keyPrefix`;
  redis-py için uygulama tarafında).
- DB numarası (`SELECT`) ACL ile kısıtlanamaz; ayrım prefix ile yapılır, herkes DB 0 kullanmalı.
- Uygulamalara kapalı komutlar:
  - `@dangerous`: `FLUSHALL`, `FLUSHDB`, `KEYS`, `CONFIG`, `INFO`, `CLIENT LIST/KILL`, `MONITOR`, `DEBUG` ...
  - `SCAN`, `RANDOMKEY`: Redis bunlara key prefix kısıtını uygulamaz; açık olursa bir uygulama
    diğerlerinin **key isimlerini** görebilir (key isminde token/session id varsa sızıntı olur).
    Kendi key'lerini listelemesi gereken uygulama bir index `SET`'i tutmalıdır.
  - `PUBSUB` (kanal listesi), `FUNCTION` (LOAD/FLUSH), `SCRIPT FLUSH/KILL`: tüm sunucuyu etkiler.
    `EVAL`/`EVALSHA`/`FCALL` açıktır; script içindeki komutlar da prefix kısıtına tabidir.
    Redis Functions gerekiyorsa `admin` ile yüklenir.
- Komut listesi `bin/init-secrets.sh` içindeki `APP_COMMANDS` değişkenindedir.
- Tek bir değer en fazla **64 MB** olabilir; daha büyük istekler reddedilir.
- Connection pool'u sınırlı tutun (örn. en fazla 50 bağlantı); bağlantı sınırı tüm uygulamalar için ortaktır.
- Key'lere TTL verin; bellek tüm uygulamalar arasında ortaktır (bkz. "Kaynak sınırları").

## Kaynak sınırları

Redis'te kullanıcı (uygulama) başına bellek, bağlantı veya CPU sınırı **yoktur**; ACL yalnızca
key ve komut erişimini sınırlar. Tüm uygulamalar aşağıdaki ortak havuzu paylaşır:

| Kaynak | Sınır | Nerede | Aşılınca |
|---|---|---|---|
| Veri belleği | 2 GB | `redis.conf` `maxmemory` | `allkeys-lru`: en az kullanılan key'ler silinir (hangi uygulamanın olduğuna bakılmaz) |
| Bağlantı buffer'ları (toplam) | 256 MB | `redis.conf` `maxmemory-clients` | En çok bellek kullanan bağlantı kapatılır |
| Tek değer boyutu | 64 MB | `redis.conf` `proto-max-bulk-len` | İstek reddedilir |
| İstemci sorgu buffer'ı | 64 MB | `redis.conf` `client-query-buffer-limit` | Bağlantı kapatılır |
| Bağlantı sayısı | 10.000 | `redis.conf` `maxclients` | Yeni bağlantılar reddedilir |
| Container belleği | 3 GB | `.env` `REDIS_MEM_LIMIT` | Container OOM ile yeniden başlar |
| CPU | 2 çekirdek | `.env` `REDIS_CPUS` | Yavaşlama (throttle) |
| İşlem sayısı | 256 | `docker-compose.yml` `pids_limit` | — |

Uygulama başına yalıtım için:

- **İzleme:** `./app.sh stats` hangi uygulamanın kaç bağlantı ve key kullandığını, eviction ve
  kapatılan/reddedilen bağlantı sayılarını gösterir. `Silinen key (evicted)` artıyorsa bellek yetmiyordur.
- **Bağlantı:** uygulama tarafında connection pool üst sınırı.
- **Bellek:** key'lerde TTL zorunlu tutulmalı. Kesin yalıtım gereken veya yoğun uygulamaya ayrı instance
  kurun (bu dizinin bir kopyası, farklı IP/port ve kendi `maxmemory` değeriyle).

`redis.conf` değiştirildiğinde `docker compose restart redis` gerekir; `.env` veya
`docker-compose.yml` değiştirildiğinde `./init.sh` container'ı yeniden oluşturur.

## Günlük işlemler

### Bağlantı testi

```sh
REDISCLI_AUTH="$(cat secrets/siparis_password)" \
  redis-cli --tls --cacert tls/ca.crt -h <SUNUCU_IP> -p 6379 --user siparis --no-auth-warning ping
```

### Durum ve loglar

```sh
docker compose ps
docker compose logs --tail 100 -f redis

# admin ile redis-cli (parola komut satırında görünmez)
REDISCLI_AUTH="$(cat secrets/admin_password)" docker compose exec -e REDISCLI_AUTH redis \
  redis-cli --tls --cacert /tls/ca.crt -h 127.0.0.1 --user admin --no-auth-warning info memory
```

Faydalı komutlar: `INFO memory`, `INFO stats` (`evicted_keys`), `INFO persistence`,
`CLIENT LIST`, `SLOWLOG GET 10`, `ACL LOG`.

### Yedekleme / geri yükleme

Veri `data/` altında AOF (`appendonlydir/`) ve RDB (`dump.rdb`) olarak tutulur. Cache olarak
kullanılıyorsa yedek şart değildir; gerekiyorsa:

```sh
# Anlık RDB al ve kopyala
REDISCLI_AUTH="$(cat secrets/admin_password)" docker compose exec -e REDISCLI_AUTH redis \
  redis-cli --tls --cacert /tls/ca.crt -h 127.0.0.1 --user admin --no-auth-warning bgsave
docker compose cp redis:/data/dump.rdb ./yedek-$(date +%F).rdb
```

Geri yükleme: `docker compose down`, `data/` içeriğini temizleyip `dump.rdb`'yi koyun
(sahibi 999:999), `appendonly` açık olduğu için ilk açılışta AOF yoksa RDB'den yüklenir; `./init.sh`.

### Loglar

Container logları Docker `json-file` ile tutulur ve döndürülür (10 MB × 5 dosya,
`docker-compose.yml` → `logging`). Merkezi log sistemi kullanılıyorsa driver orada değiştirilir.

### Sunucu IP'si değişirse

`.env` içinde `REDIS_BIND_IP` güncellenir (veya boşaltılıp seçtirilir). Sertifika eski IP'yi
içerdiği için `init.sh` durur; sertifikayı yenileyin (bkz. "Sertifika yenileme") ve istemcilere
yeni adresi bildirin.

### Redis sürüm güncellemesi

```sh
# .env: REDIS_VERSION=<yeni sürüm>, REDIS_IMAGE=   (boş)
./init.sh
```

Yeni image çekilir, digest `.env`'e yazılır ve container yeniden oluşturulur (kısa kesinti;
veri AOF'tan geri yüklenir).

### Sertifika yenileme

`init.sh`, sertifikanın bitmesine 30 günden az kalmışsa uyarır. Yenilemek için (CA aynı kalır,
istemcilerde değişiklik gerekmez):

```sh
docker run --rm -v "$PWD/tls:/t" --entrypoint rm "$(grep ^REDIS_IMAGE= .env | cut -d= -f2)" -f /t/redis.crt /t/redis.key
./init.sh
docker compose restart redis
```

`pki/ca.key` sunucudan kaldırıldıysa önce geri koyun.

### Kaldırma / sıfırdan kurulum

```sh
docker compose down
# Üretilen tüm dosyalar (VERİ, sertifikalar, parolalar dahil) silinir:
docker run --rm --network none -v "$PWD:/w" -w /w --entrypoint sh "$(grep ^REDIS_IMAGE= .env | cut -d= -f2)" -c \
  'rm -rf .env pki config/users.acl config/apps data tls/*.crt tls/*.key tls/*.srl secrets/*_password
   mkdir data && touch data/.gitkeep && chown '"$(id -u):$(id -g)"' data data/.gitkeep'
./init.sh
```

Uygulama listesini korumak için `config/apps`'i silmeyin; `init.sh` kullanıcıları yeni parolalarla yeniden oluşturur.

## Sorun giderme

| Belirti | Neden / çözüm |
|---|---|
| `REDIS_BIND_IP=... bu host'ta tanımlı değil` | `.env`'deki IP bu sunucuda yok. Satırı boşaltıp `./init.sh` ile yeniden seçtirin. |
| `redis.crt, REDIS_BIND_IP=... adresini içermiyor` | IP değişmiş; "Sertifika yenileme" adımlarını uygulayın. |
| `başka bir init.sh / app.sh çalışıyor` | Başka bir oturum çalışıyor; bitmesini bekleyin. |
| `container healthy olmadı` | Script son 50 log satırını basar. Çoğunlukla TLS dosyası, izin veya `users.acl` hatasıdır. |
| İstemcide `WRONGPASS` | Parola yanlış veya `rotate` edilmiş. Parola dosyasının içeriğini (sonunda boşluk/satır sonu olmadan) kullanın. |
| İstemcide `NOPERM ... key` | Key, uygulamanın prefix'i (`<isim>:`) ile başlamıyor. |
| İstemcide `NOPERM ... command` | Komut uygulamalara kapalı (bkz. "Uygulamalar için kurallar"). |
| İstemcide TLS / sertifika hatası | İstemci `tls/ca.crt` ile doğrulama yapmalı; bağlandığı IP/DNS adı sertifikanın SAN listesinde olmalı. |
| Logda `wrong version number` | Biri TLS'siz bağlanmaya çalışıyor (`init.sh` testleri de bunu bir kez üretir). |
| Logda `vm.overcommit_memory` uyarısı | "Gereksinimler"deki sysctl ayarını yapın. |
| İstemcide `Protocol error: invalid bulk length` | Değer 64 MB sınırını aşıyor (`proto-max-bulk-len`). |
| Bağlantılar beklenmedik kopuyor | `./app.sh stats` → `Kapatılan bağlantı` artıyorsa büyük yanıtlar `maxmemory-clients` sınırını aşıyor. |
| `Silinen key (evicted)` artıyor | Bellek yetmiyor: TTL'leri kısaltın, `maxmemory`'yi artırın veya yoğun uygulamayı ayırın. |

## Notlar

- `maxmemory` + `maxmemory-clients` (`config/redis.conf`, 2gb + 256mb) ile `REDIS_MEM_LIMIT`
  (`.env`, 3g) birlikte değiştirilmeli; fork (BGSAVE/AOF rewrite) sırasında COW için pay bırakın.
- `config/users.acl` `init.sh` / `app.sh` tarafından üretilir ve `ACL LOAD` ile yüklenir.
  Elle düzenlemeyin; `ACL SETUSER` + `ACL SAVE` kullanmayın (dosya read-only mount, değişiklikler kaybolur).

## Firewall

Docker, publish ettiği portlar için kendi iptables (NAT) kurallarını ekler. Bu yüzden **ufw /
firewalld / iptables INPUT kuralları bu portu korumaz**; `ufw deny 6379` yazılsa bile Redis
erişilebilir kalır. Kısıtlama Docker'ın her zaman önce işlettiği `DOCKER-USER` zincirine yazılmalıdır:

```sh
# Örnek: yalnızca 10.0.10.0/24 (uygulama sunucuları) ve 10.0.20.5 (LB) erişsin
REDIS_IP=<REDIS_BIND_IP>
PORT=6379   # REDIS_PUBLISHED_PORT
M="-p tcp -m conntrack --ctorigdst $REDIS_IP --ctorigdstport $PORT"

sudo iptables -I DOCKER-USER $M -j DROP
sudo iptables -I DOCKER-USER $M -s 10.0.20.5 -j ACCEPT
sudo iptables -I DOCKER-USER $M -s 10.0.10.0/24 -j ACCEPT
sudo iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

- `DOCKER-USER` paketleri DNAT'tan **sonra** görür (hedef artık container IP'sidir); bu yüzden
  `-d <host IP>` eşleşmez, orijinal hedef `--ctorigdst/--ctorigdstport` ile eşleştirilir.
- `-I` başa ekler; son hâlde sıra: ESTABLISHED → izinli kaynaklar → DROP.
  Kontrol: `sudo iptables -L DOCKER-USER -n -v --line-numbers`
- Kurallar reboot'ta kaybolur; `iptables-persistent` (Debian/Ubuntu) veya kurumun firewall yönetimiyle kalıcı yapın.
- Test: izinli olmayan bir makineden `nc -vz <REDIS_BIND_IP> 6379` zaman aşımına uğramalı.

## Güvenlik notları

- **Sürüm güncel tutulmalı.** Eski Redis sürümlerinde kimliği doğrulanmış kullanıcının Lua
  üzerinden kod çalıştırabildiği kritik açıklar var (örn. CVE-2025-49844). Bkz. "Redis sürüm güncellemesi".
- **CA anahtarı (`pki/ca.key`)** ile bu Redis adına sahte sertifika üretilebilir. Kurulumdan sonra
  sunucudan alıp güvenli bir yerde saklayın; sertifika yenilerken geri koyun.
- **Parolalar:** `secrets/*_password` yalnızca kurulum kullanıcısı tarafından okunabilir (0600).
  Uygulama ekiplerine güvenli kanal/vault ile iletin; e-posta/chat/git'e koymayın.
  Sızma şüphesinde `./app.sh rotate <isim>`: eski parola anında geçersiz olur, açık bağlantılar kapatılır.
- **Veri:** `data/` 0700; AOF/RDB şifresiz tutulur. Cache'e hassas veri yazılıyorsa diski ve yedekleri buna göre koruyun.
- **Ağ:** 6379'a yalnızca uygulama sunucularından / LB'den izin verin. Docker'ın açtığı portlar
  ufw/firewalld INPUT kurallarını **atlar**; kural `DOCKER-USER` zincirine yazılmalıdır (bkz. "Firewall").
- **docker grubu** root yetkisine eşdeğerdir; bu sunucuda docker grubundaki herkes parolalara ve veriye erişebilir.

## Load balancer arkasında çalıştırma

Bu yapı **tek bir standalone Redis** örneğidir. Load balancer (HAProxy, F5, Nginx stream vb.)
önüne konulabilir ama aşağıdaki kurallara uyulmalıdır.

### Topoloji

```
 uygulamalar ──TLS──▶  LB VIP :6379  ──TLS (passthrough)──▶  <SUNUCU_IP>:6379 (main-redis)
                                     └─ (opsiyonel backup) ─▶  ikinci node
```

- **Aktif-aktif (round-robin) dağıtım YAPMAYIN.** Node'lar arasında replikasyon yoksa her node
  ayrı veri tutar; istemci her bağlantıda farklı veri görür. Backend'lerden yalnızca biri aktif
  olmalı, diğeri `backup` olarak tanımlanmalı.
- Backup node'a geçişte o node'un verisi boştur (cache olduğu için kabul edilebilir olmalı).
  Veri kaybı istenmiyorsa replikasyon + Sentinel kurulmalı ve LB yalnızca `role:master` olan
  node'a trafik göndermelidir (bkz. aşağıdaki "Replikasyon ile" notu).

### LB ayarları

| Konu | Öneri |
|---|---|
| Mod | L4 / TCP (HTTP modu kullanılamaz) |
| TLS | **Passthrough** — TLS Redis'te sonlanır. LB'de sonlandırılacaksa backend'e tekrar TLS ile bağlanmalı (`port 0` olduğu için plaintext çalışmaz). |
| Sertifika | `tls/redis.crt` SAN listesinde **LB VIP'i / DNS adı** ve node IP'leri bulunmalı; istemciler VIP adıyla doğrulama yapar. İlk kurulumdan önce `.env` içinde `REDIS_TLS_EXTRA_SAN` ile verin (bkz. "LB / DNS adı ile kurulum"). |
| Idle timeout | `tcp-keepalive 300` olduğundan LB client/server timeout **≥ 10 dk** olmalı. Pub/Sub ve `BLPOP` gibi bloklayan komutlar kullanılıyorsa daha da uzun tutun, aksi halde LB bağlantıyı sessizce keser. |
| Persistence / stickiness | Gerek yok (tek aktif backend). |
| Health check | TCP connect yeterli değildir (Redis `LOADING` durumundayken de port açıktır). TLS üzerinden `AUTH` + `PING` → `+PONG` kontrolü yapın. |
| Kaynak IP | Redis PROXY protocol desteklemez; Redis loglarında ve `CLIENT LIST`'te istemci olarak LB IP'si görünür. LB'de `send-proxy` **açmayın**. |
| Bağlantı sayısı | LB `maxconn` değeri redis.conf `maxclients 10000` değerinin altında olmalı. |

### Firewall (LB)

Doğrudan erişimde olduğu gibi `DOCKER-USER` zincirine yalnızca **LB IP'lerini** yazın; istemcilerin
LB'yi atlayıp doğrudan node'a bağlanmasını engelleyin (bkz. "Firewall").

### Örnek: HAProxy

```haproxy
defaults
    mode    tcp
    timeout connect 5s
    timeout client  15m
    timeout server  15m

frontend redis_fe
    bind <VIP>:6379                 # LB sanal IP
    maxconn 8000
    default_backend redis_be

backend redis_be
    option tcp-check
    tcp-check connect ssl
    tcp-check send AUTH\ healthcheck\ <HEALTHCHECK_PASSWORD>\r\n
    tcp-check expect string +OK
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send QUIT\r\n
    tcp-check expect string +OK

    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    # TLS passthrough: "server" satırında ssl YOK, health check ise "check-ssl" ile TLS kullanır
    server redis1 <SUNUCU_1_IP>:6379 check check-ssl verify required ca-file /etc/haproxy/redis-ca.crt
    server redis2 <SUNUCU_2_IP>:6379 check check-ssl verify required ca-file /etc/haproxy/redis-ca.crt backup
```

- `<HEALTHCHECK_PASSWORD>` = `secrets/healthcheck_password` içeriği. `healthcheck` kullanıcısı
  yalnızca `PING` yetkisine sahip olduğu için LB config'inde durması düşük risklidir; yine de
  haproxy.cfg dosyasını `0640 root:haproxy` yapın.
- `on-marked-down shutdown-sessions`: aktif node düşünce mevcut bağlantılar kapatılır,
  istemciler yeniden bağlanıp backup'a geçer.
- Aktif node geri geldiğinde HAProxy trafiği tekrar ona taşır; cache'in iki kez soğuk
  başlamasını istemiyorsanız backup'a `server ... backup` yerine manuel failover tercih edin.

### Replikasyon ile (opsiyonel)

İki node arasında replikasyon kurulursa LB yalnızca master'a yönlendirmelidir:

1. `healthcheck` kullanıcısına `+info` yetkisi ekleyin. `config/users.acl` her çalıştırmada
   yeniden üretildiği için elle değil, `bin/init-secrets.sh` içindeki healthcheck satırında
   değiştirin (`... -@all +ping +info`) ve `./init.sh` çalıştırın.
2. Health check'i master kontrolüne çevirin:

   ```haproxy
   tcp-check send INFO\ replication\r\n
   tcp-check expect string role:master
   ```
3. Bu durumda `backup` satırını kaldırın; iki node da normal `server` olarak tanımlanır,
   yalnızca master health check'ten geçer. Failover'ı Sentinel yönetir.

### İstemci tarafı

- Bağlantı adresi node IP'si değil **VIP / LB DNS adı** olmalı.
- TLS doğrulamasında `ca.crt` kullanılmalı ve hostname olarak VIP DNS adı verilmeli.
- Failover sırasında bağlantılar kopar; istemci kütüphanesinde otomatik yeniden bağlanma
  (retry/backoff) açık olmalı.
