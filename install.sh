#!/bin/bash

# Renk kodları
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Varsayılan değerler
# Agent binary'leri public archive'den indirilir (clustereye-agent private).
# 'latest' dizini, archive'in pull workflow'u tarafından en son sürümle güncel tutulur.
RELEASE_URL="https://archive.clustereye.com/downloads/agent/latest"
INSTALL_DIR="/opt/clustereye"
SERVICE_NAME="clustereye-agent"
LOCAL_BINARY=""
INSECURE=0
API_URL=""
REGISTRATION_TOKEN=""
TLS_ENABLED=0
# Sürüme sabitlenmiş kurulum. ClusterEye arayüzü bu üçünü release manifest'inden
# okuyup komuta koyuyor; verildiklerinde ham binary yerine paket indirilir ve
# bütünlüğü doğrulanmadan hiçbir şey diske yerleşmez.
PACKAGE_URL=""
LOCAL_PACKAGE=""
EXPECTED_SHA256=""
AGENT_VERSION=""

# Kullanım bilgisi
usage() {
    echo -e "${YELLOW}ClusterEye Agent Kurulum Scripti${NC}"
    echo -e "Kullanım: $0 -p <platform> [--api-url <host>] [--registration-token <token>] [-d <install-dir>] [-b <local-binary>] [-k]"
    echo -e "\nParametreler:"
    echo -e "  -p, --platform             Platform (zorunlu): postgres, mongo, mssql, mysql, oracle, clickhouse"
    echo -e "  --api-url                  ClusterEye API sunucu adresi (UI üzerinden kurulum için)"
    echo -e "  --registration-token       UI'dan üretilen tek kullanımlık registration token"
    echo -e "  -d, --install-dir          Kurulum dizini (varsayılan: /opt/clustereye)"
    echo -e "  -b, --local-binary         Lokal binary yolu (release indirme yerine bunu kopyalar)"
    echo -e "  --package-url <url>        İndirilecek agent paketi (.tar.gz). --sha256 ile birlikte zorunlu."
    echo -e "  --local-package <path>     Lokal agent paketi (air-gapped). --sha256 ile birlikte zorunlu."
    echo -e "  --sha256 <hex>             Paketin beklenen SHA-256 özeti"
    echo -e "  --version <x.y.z>          Kurulan agent sürümü (yalnızca kayıt/gösterim)"
    echo -e "  --tls                      gRPC bağlantısında TLS kullan (varsayılan: kapalı)"
    echo -e "  -k, --insecure             TLS sertifika doğrulamasını devre dışı bırak (--tls ile birlikte)"
    echo -e "  -h, --help                 Bu yardım mesajını göster"
    exit 1
}

# Argümanları ayrıştır — hem kısa (-p) hem uzun (--api-url) flag destekli.
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--platform)            PLATFORM="$2"; shift 2;;
        -d|--install-dir)         INSTALL_DIR="$2"; shift 2;;
        -b|--local-binary)        LOCAL_BINARY="$2"; shift 2;;
        --package-url)            PACKAGE_URL="$2"; shift 2;;
        --local-package)          LOCAL_PACKAGE="$2"; shift 2;;
        --sha256)                 EXPECTED_SHA256="$2"; shift 2;;
        --version)                AGENT_VERSION="$2"; shift 2;;
        --api-url)                API_URL="$2"; shift 2;;
        --registration-token)     REGISTRATION_TOKEN="$2"; shift 2;;
        --tls)                    TLS_ENABLED=1; shift;;
        -k|--insecure)            INSECURE=1; shift;;
        -h|--help)                usage;;
        *) echo -e "${RED}Bilinmeyen parametre: $1${NC}"; usage;;
    esac
done

# Platform parametresini kontrol et.
#
# Bu liste, API'nin ürettiği "-p <flag>" değerleriyle birebir uyuşmak ZORUNDA.
# Kaynağı: clustereye-api/internal/api/agent_bootstrap_handler.go içindeki
# supportedPlatforms tablosu. İki repo arasında otomatik bir bağ yok — bu script
# archive.clustereye.com'dan curl ile çekilip API'yi hiç tanımayan bir makinede
# çalışıyor. Uyumu oradaki agent_bootstrap_platforms_test.go sözleşme testi
# koruyor; clickhouse tam da bu boşluktan düşmüştü.
if [ -z "$PLATFORM" ] || [[ ! "$PLATFORM" =~ ^(postgres|mongo|mssql|mysql|oracle|clickhouse)$ ]]; then
    echo -e "${RED}Hata: Geçerli bir platform belirtilmedi (postgres, mongo, mssql, mysql, oracle, clickhouse)${NC}"
    usage
fi

# --- Bütünlük doğrulaması --------------------------------------------------
#
# Bu script archive.clustereye.com'dan çekilip doğrudan `sudo bash`'e pipe
# ediliyor ve indirdiği binary'yi root altında systemd servisi olarak
# çalıştırıyor. İndirileni doğrulamak bu yüzden isteğe bağlı bir güzellik değil.

# Bir paket URL'i/dosyası verildiyse özet de verilmek ZORUNDA. Aksi halde
# saldırganın doğrulamayı devre dışı bırakması tek bayrak düşürmeye iner.
if { [ -n "$PACKAGE_URL" ] || [ -n "$LOCAL_PACKAGE" ]; } && [ -z "$EXPECTED_SHA256" ]; then
    echo -e "${RED}Hata: --package-url/--local-package ile --sha256 birlikte verilmelidir.${NC}"
    usage
fi
if [ -n "$PACKAGE_URL" ] && [ -n "$LOCAL_PACKAGE" ]; then
    echo -e "${RED}Hata: --package-url ve --local-package birlikte kullanılamaz.${NC}"
    usage
fi

# Özet hesaplayıcıyı baştan seç. GNU coreutils, macOS/BSD ve Solaris farklı
# araçlar sunuyor.
SHA_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA_TOOL="shasum -a 256"
elif command -v digest >/dev/null 2>&1; then
    # Solaris/illumos
    SHA_TOOL="digest -a sha256"
fi

# sha256_of, dosyanın özetini küçük harfli hex olarak yazar.
sha256_of() {
    case "$SHA_TOOL" in
        digest*) $SHA_TOOL "$1" | tr 'A-Z' 'a-z' ;;
        *)       $SHA_TOOL "$1" | awk '{print $1}' | tr 'A-Z' 'a-z' ;;
    esac
}

# verify_sha256 <dosya>. Uyuşmazlıkta dosyayı siler ve çıkar.
#
# Bilinçli olarak `sha256sum -c` kullanmıyoruz: yan dosya formatı özeti build
# zamanındaki DOSYA ADINA bağlıyor, bizim geçici dosya adımız farklı.
verify_sha256() {
    local file="$1" actual expected
    expected=$(echo "$EXPECTED_SHA256" | tr 'A-Z' 'a-z')

    if [ -z "$SHA_TOOL" ]; then
        # "Hesaplayıcı yok" asla "doğrulamayı atla"ya dönüşmemeli.
        echo -e "${RED}Hata: SHA-256 aracı bulunamadı (sha256sum/shasum/digest).${NC}"
        echo -e "${RED}Doğrulanmamış bir binary kurulmayacak.${NC}"
        rm -f "$file"
        exit 1
    fi

    actual=$(sha256_of "$file")
    if [ "$actual" != "$expected" ]; then
        echo -e "${RED}Bütünlük doğrulaması BAŞARISIZ — kurulum durduruldu.${NC}"
        echo -e "${RED}  beklenen: $expected${NC}"
        echo -e "${RED}  bulunan : $actual${NC}"
        echo -e "${RED}Dosya silindi. Çalışan agent'a dokunulmadı.${NC}"
        rm -f "$file"
        exit 1
    fi
    echo -e "${GREEN}   SHA-256 doğrulandı.${NC}"
}

# Bootstrap modu: --api-url ve --registration-token birlikte verilmelidir.
BOOTSTRAP_MODE=0
if [ -n "$API_URL" ] || [ -n "$REGISTRATION_TOKEN" ]; then
    if [ -z "$API_URL" ] || [ -z "$REGISTRATION_TOKEN" ]; then
        echo -e "${RED}Hata: --api-url ve --registration-token birlikte verilmelidir.${NC}"
        usage
    fi
    BOOTSTRAP_MODE=1
    # API adresine port yoksa varsayılan gRPC portu (50051) eklenir.
    case "$API_URL" in
        *:*) GRPC_ADDRESS="$API_URL";;
        *)   GRPC_ADDRESS="$API_URL:50051";;
    esac
fi

# Root yetkisi kontrol — bash'in EUID'i, Solaris /bin/sh'in id -u'su
if [ -n "$EUID" ]; then
    CURRENT_UID="$EUID"
else
    CURRENT_UID="$(id -u 2>/dev/null || echo 0)"
fi
if [ "$CURRENT_UID" -ne 0 ]; then
    echo -e "${RED}Bu script root yetkileri ile çalıştırılmalıdır.${NC}"
    echo -e "Lütfen 'sudo $0' şeklinde çalıştırın."
    exit 1
fi

echo -e "${YELLOW}ClusterEye Agent kurulumu başlatılıyor...${NC}"
echo "Platform: $PLATFORM"
echo "Kurulum dizini: $INSTALL_DIR"

# İşletim sistemini belirle (Linux | SunOS=Solaris/illumos)
OS_NAME=$(uname -s)
case "$OS_NAME" in
    Linux)
        BINARY_OS="linux"
        ;;
    SunOS)
        BINARY_OS="solaris"
        ;;
    *)
        echo -e "${RED}Desteklenmeyen işletim sistemi: $OS_NAME${NC}"
        exit 1
        ;;
esac

# Sistem mimarisini belirle
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64|i86pc)
        # i86pc = Solaris/illumos x86_64
        BINARY_ARCH="amd64"
        ;;
    aarch64|arm64)
        # arm64 için yayınlanmış bir binary YOK — release pipeline'ı yalnızca
        # linux/amd64 ve windows/amd64 üretiyor. Buraya "arm64" yazıp devam
        # etmek 404'e ya da (-b ile) amd64 binary'sinin arm64 adıyla kurulup
        # servisin "Exec format error" ile çırpınmasına yol açıyordu.
        echo -e "${RED}Desteklenmeyen sistem mimarisi: $ARCH${NC}"
        echo -e "${RED}ClusterEye agent şu anda yalnızca linux/amd64 için yayınlanıyor.${NC}"
        exit 1
        ;;
    *)
        echo -e "${RED}Desteklenmeyen sistem mimarisi: $ARCH${NC}"
        exit 1
        ;;
esac

echo "İşletim sistemi: $BINARY_OS"
echo "Mimari: $BINARY_ARCH"

# Kurulum dizinini oluştur
echo -e "\n${YELLOW}1. Kurulum dizini oluşturuluyor...${NC}"
mkdir -p "$INSTALL_DIR"

# Binary'i sağla — lokal verildiyse kopyala, aksi halde release'den indir.
# Solaris için release'de henüz binary yok; -b ile lokal verilmesi zorunludur.
BINARY_NAME="clustereye-agent-${BINARY_OS}-${BINARY_ARCH}"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"

CURL_OPTS="-fL"
if [ "$INSECURE" = "1" ]; then
    CURL_OPTS="$CURL_OPTS -k"
fi

# İndirilenler önce geçici dizine iner. Eskiden doğrudan $BINARY_PATH'e
# indiriliyordu, yani doğrulama şansı doğmadan çalışan agent'ın binary'si
# eziliyordu.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

if [ -n "$LOCAL_PACKAGE" ] || [ -n "$PACKAGE_URL" ]; then
    # --- Paket modu: sürüme sabitlenmiş, doğrulanmış kurulum ---
    #
    # Paket, ham binary'nin aksine updater'ı da içeriyor. install.sh yıllarca
    # yalnızca ham binary kurduğu için bu yolla kurulan agent'lar kendilerini
    # güncelleyemiyordu (reporter.go updater'ı kurulum dizininde arıyor).
    PKG="$STAGE_DIR/agent-package.tar.gz"

    if [ -n "$LOCAL_PACKAGE" ]; then
        echo -e "\n${YELLOW}2. Lokal paket doğrulanıyor: $LOCAL_PACKAGE${NC}"
        if [ ! -f "$LOCAL_PACKAGE" ]; then
            echo -e "${RED}Lokal paket bulunamadı: $LOCAL_PACKAGE${NC}"
            exit 1
        fi
        cp "$LOCAL_PACKAGE" "$PKG" || { echo -e "${RED}Paket kopyalanamadı!${NC}"; exit 1; }
    else
        echo -e "\n${YELLOW}2. Agent paketi indiriliyor${NC}"
        [ -n "$AGENT_VERSION" ] && echo "   Sürüm: $AGENT_VERSION"
        echo "   URL: $PACKAGE_URL"
        [ "$INSECURE" = "1" ] && echo -e "   ${YELLOW}Uyarı: -k aktif, TLS sertifikası doğrulanmıyor.${NC}"
        if ! curl $CURL_OPTS -o "$PKG" "$PACKAGE_URL"; then
            echo -e "${RED}Paket indirme hatası!${NC}"
            echo -e "${RED}Bu komut bir sürüme sabitlenmiş ve o sürüm arşivden kaldırılmış olabilir.${NC}"
            echo -e "${RED}ClusterEye arayüzünden kurulum komutunu yeniden üretin.${NC}"
            exit 1
        fi
    fi

    # Doğrulama, arşivi AÇMADAN önce: arşiv açmak da bir saldırı yüzeyi.
    verify_sha256 "$PKG"

    echo -e "\n${YELLOW}   Paket açılıyor...${NC}"
    if ! tar xzf "$PKG" -C "$INSTALL_DIR"; then
        echo -e "${RED}Paket açılamadı!${NC}"
        exit 1
    fi
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}Paket beklenen binary'yi içermiyor: $BINARY_NAME${NC}"
        exit 1
    fi
    [ -f "$INSTALL_DIR/clustereye-agent-updater" ] && chmod +x "$INSTALL_DIR/clustereye-agent-updater"

elif [ -n "$LOCAL_BINARY" ]; then
    echo -e "\n${YELLOW}2. Lokal binary kopyalanıyor: $LOCAL_BINARY${NC}"
    if [ ! -f "$LOCAL_BINARY" ]; then
        echo -e "${RED}Lokal binary bulunamadı: $LOCAL_BINARY${NC}"
        exit 1
    fi
    cp "$LOCAL_BINARY" "$STAGE_DIR/$BINARY_NAME" || { echo -e "${RED}Binary kopyalama hatası!${NC}"; exit 1; }
    # --sha256 verildiyse lokal dosya da doğrulanır; air-gapped kurulumda
    # operatörün eline geçen tek kontrol bu.
    [ -n "$EXPECTED_SHA256" ] && verify_sha256 "$STAGE_DIR/$BINARY_NAME"
    mv "$STAGE_DIR/$BINARY_NAME" "$BINARY_PATH"

else
    # --- Eski yol: sabitlenmemiş ham binary ---
    # Yeni bayrakları göndermeyen bir API veya elle çağrım bu dalı kullanır;
    # davranış eskisiyle birebir aynı kalsın diye korunuyor.
    echo -e "\n${YELLOW}2. Agent binary dosyası indiriliyor...${NC}"
    echo "   URL: $RELEASE_URL/$BINARY_NAME"
    [ "$INSECURE" = "1" ] && echo -e "   ${YELLOW}Uyarı: -k aktif, TLS sertifikası doğrulanmıyor.${NC}"
    if ! curl $CURL_OPTS -o "$STAGE_DIR/$BINARY_NAME" "$RELEASE_URL/$BINARY_NAME"; then
        echo -e "${RED}Binary indirme hatası!${NC}"
        echo -e "${RED}URL'in geçerli olduğundan ve asset adının '$BINARY_NAME' olduğundan emin olun.${NC}"
        echo -e "${RED}TLS hatası alıyorsanız (eski CA bundle): scripti -k flag ile çalıştırın.${NC}"
        exit 1
    fi
    echo -e "   ${YELLOW}Uyarı: sürüm sabitlenmedi, bütünlük doğrulaması yapılmıyor.${NC}"
    echo -e "   ${YELLOW}Doğrulanmış kurulum için komutu ClusterEye arayüzünden üretin.${NC}"
    mv "$STAGE_DIR/$BINARY_NAME" "$BINARY_PATH"
fi

# Çalıştırma yetkisi ver
chmod +x "$BINARY_PATH"

# Yapılandırma dosyasını oluştur
echo -e "\n${YELLOW}3. Yapılandırma dosyası oluşturuluyor...${NC}"
if [ "$BOOTSTRAP_MODE" = "1" ]; then
    # Bootstrap modu: minimal config üretilir. DB bağlantı bilgileri (user/pass/
    # instance vb.) ClusterEye arayüzünden girilir ve gRPC ile agent'a iletilir.
    # agent.yml her kurulumda yeniden yazılır (idempotent re-run).
    HOSTNAME_VAL="$(hostname 2>/dev/null || echo clustereye-agent)"
    if [ "$INSECURE" = "1" ]; then SKIP_VERIFY="true"; else SKIP_VERIFY="false"; fi
    if [ "$TLS_ENABLED" = "1" ]; then TLS_VALUE="true"; else TLS_VALUE="false"; fi
    cat > "$INSTALL_DIR/agent.yml" << EOF
name: $HOSTNAME_VAL
grpc:
  server_address: $GRPC_ADDRESS
  tls_enabled: $TLS_VALUE
  insecure_skip_verify: $SKIP_VERIFY
auth:
  registration_token: $REGISTRATION_TOKEN
logging:
  level: "INFO"
  use_filelog: true
security:
  enabled: true
  scan_interval_hours: 6
EOF
    chmod 600 "$INSTALL_DIR/agent.yml"
    echo -e "${GREEN}Bootstrap yapılandırması yazıldı. DB bağlantı bilgileri ClusterEye arayüzünden tamamlanacak.${NC}"
elif [ -f "$INSTALL_DIR/agent.yml" ]; then
    echo -e "${YELLOW}Mevcut agent.yml bulundu, üzerine yazılmadı.${NC}"
else
    cat > "$INSTALL_DIR/agent.yml" << 'EOF'
name: Agent
grpc:
  server_address: 10.1.242.65:30000
  tls_enabled: false              # Enable TLS for secure connection
  insecure_skip_verify: false     # Skip TLS certificate verification (use only for development)
postgresql:
  host: 10.1.X.X
  user:
  pass:
  port: 5432
  cluster: 99d4XXXX
  location: istanbul
  # Query Monitoring Configuration
  query_monitoring:
    enabled: true                           # Enable query performance monitoring
    method: "pg_stat_statements"            # Primary collection method: "pg_stat_statements", "pg_stat_activity", or "combined"
    fallback_methods: ["pg_stat_activity"]  # Fallback methods if primary fails
    collection_interval_sec: 60             # Collection interval in seconds (minimum 10s)
    max_queries_per_collection: 1000        # Maximum queries per collection cycle
    max_query_text_length: 4000             # Maximum query text length to capture
    cpu_threshold_percent: 80.0             # CPU threshold to throttle collection
    memory_limit_mb: 50                     # Memory limit for query collection
    min_execution_count: 1                  # Minimum executions to include query
    min_duration_ms: 100.0                  # Minimum duration (ms) to include query
    include_system_queries: false           # Include system/internal queries
    include_adhoc_queries: true             # Include ad-hoc queries
    pg_stat_statements_track: "all"         # pg_stat_statements tracking level: "all", "top", "none"
    pg_stat_statements_max_size: 5000       # Max statements tracked by pg_stat_statements
    pg_stat_activity_interval_sec: 15       # pg_stat_activity collection interval
oracle:
  enabled: false                  # Oracle koleksiyonunu açmak için true yapın
  driver: "go-ora"                # "go-ora" (default) | "godror" (build-tag gerektirir)
  mode: "cdb_root"                # "cdb_root" (default) | "pdb_service"
  host: 10.1.X.X
  port: "1521"
  service_name:                   # service_name veya sid'den biri zorunludur
  sid:
  container_name:                 # Opsiyonel (PDB adı)
  user:
  pass:
  connect_as_role:                # "" | "SYSDBA" | "SYSOPER"
  cluster: 99d4XXXX
  location: istanbul
  tls:
    enabled: false
    wallet_path:
  limits:
    max_top_sql: 25
    max_wait_events: 15
    max_session_buckets: 10
    enable_active_sessions_snapshot: false
    max_blocking_sessions: 20
    max_temp_rows: 10
    max_pdbs: 50
  collectors:
    redo: true
    buffer_cache: true
    parse: true
    resource_limits: true
    blocking: true
    temp_usage: true
    undo: true
    io: true
    pga: true
    dataguard: true
    pdb: true
    sql_wait_profile: true
    redo_pressure: true
    segment_io: true
    library_cache: true
    workarea: true
    latch_mutex: true
    dbwr_pressure: true
    tables: true
  privacy:
    collect_sql_text: true
    sql_text_max_length: 1000
    strip_bind_values: true
    sanitize_control: true
  query_monitoring:
    enabled: true
    collection_interval_sec: 60
  tuning:
    enabled: false                # SQL Tuning / Object Insights opt-in
    interval_seconds: 0
    max_sql_candidates: 0
    max_objects: 0
    max_indexes: 0
    sql_text_max_length: 0
    enable_predicate_parsing: false
    enable_index_recommendations: false
    min_table_rows_for_index_recommendation: 0
    min_buffer_gets_per_exec: 0
    min_disk_reads_per_exec: 0
    stale_stats_days: 0
    hot_physical_reads: 0
    hot_buffer_busy_waits: 0
    hot_itl_waits: 0
    plan_instability_min_execs: 0
    plan_instability_ratio: 0
    bind_literal_min_distinct: 0
mysql:
  # MySQL Connection Settings. Leave blank when the agent is bootstrapped
  # via the UI — the UI's onboarding flow pushes host/user/pass down via
  # the DatabaseConfigRequest gRPC command after registration.
  host: 10.1.X.X
  port: "3306"
  user:
  pass:
  database:                       # optional; leave empty for server-level metrics
  cluster: 99d4XXXX
  location: istanbul
  ssl_mode:                       # one of: "true" | "false" | "skip-verify" | "preferred"
  # Optional replication user (for replica monitoring). If empty, the
  # main monitoring user is used for replication probes too.
  replication_user:
  replication_password:
# Logging Configuration
logging:
  level: "INFO"         # Log level: DEBUG, INFO, WARNING, ERROR, FATAL
  use_eventlog: true    # Use Windows Event Log (Windows only)
  use_filelog: true     # Use file logging
config_drift:
  enabled: true
  mssql_poll_interval_sec: 60
security:
  enabled: true
  scan_interval_hours: 6  # Her 6 saatte bir (default)
EOF
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}Yapılandırma dosyası oluşturma hatası!${NC}"
    exit 1
fi

# Servis tanımını oluştur — Linux'ta systemd, Solaris'te SMF
if [ "$BINARY_OS" = "linux" ]; then
    echo -e "\n${YELLOW}4. Systemd service dosyası oluşturuluyor...${NC}"
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=ClusterEye Agent Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_DIR/$BINARY_NAME -platform $PLATFORM
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
Environment=PATH=/usr/bin:/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    if [ "$BOOTSTRAP_MODE" = "1" ]; then
        # Bootstrap modu: servis otomatik başlatılır, elle yapılandırma gerekmez.
        echo -e "\n${YELLOW}4. Servis başlatılıyor...${NC}"
        systemctl enable --now "$SERVICE_NAME"
        echo -e "\n${GREEN}Kurulum tamamlandı ve agent başlatıldı!${NC}"
        echo -e "\n${YELLOW}Agent ClusterEye API'ye bağlanıyor.${NC}"
        echo "Birkaç saniye içinde ClusterEye arayüzünde görünecek ve oradan"
        echo "veritabanı bağlantı bilgilerini girebileceksiniz."
        echo -e "\nServis durumu:  sudo systemctl status $SERVICE_NAME"
        echo -e "Loglar:         sudo journalctl -u $SERVICE_NAME -f"
    else
        echo -e "\n${GREEN}Kurulum tamamlandı!${NC}"
        echo -e "\n${YELLOW}Önemli:${NC}"
        echo "1. Yapılandırma dosyasını düzenleyin:"
        echo "   sudo nano $INSTALL_DIR/agent.yml"
        echo -e "\n2. Servisi başlatın:"
        echo "   sudo systemctl start $SERVICE_NAME"
        echo "   sudo systemctl enable $SERVICE_NAME"
        echo -e "\n3. Servis durumunu kontrol edin:"
        echo "   sudo systemctl status $SERVICE_NAME"
        echo -e "\n4. Logları izleyin:"
        echo "   sudo journalctl -u $SERVICE_NAME -f"
    fi

elif [ "$BINARY_OS" = "solaris" ]; then
    echo -e "\n${YELLOW}4. SMF manifest ve method script oluşturuluyor...${NC}"

    # Method script — SMF stdout/stderr'i $INSTALL_DIR/agent.log'a yönlendirir
    METHOD_SCRIPT="$INSTALL_DIR/svc-clustereye-agent"
    cat > "$METHOD_SCRIPT" << EOF
#!/bin/sh
. /lib/svc/share/smf_include.sh

case "\$1" in
    start)
        cd "$INSTALL_DIR" || exit \$SMF_EXIT_ERR_FATAL
        exec "$INSTALL_DIR/$BINARY_NAME" -platform $PLATFORM >> "$INSTALL_DIR/agent.log" 2>&1
        ;;
    *)
        echo "Usage: \$0 start"
        exit \$SMF_EXIT_ERR_CONFIG
        ;;
esac
exit \$SMF_EXIT_OK
EOF
    chmod +x "$METHOD_SCRIPT"

    # SMF manifest
    MANIFEST_DIR="/var/svc/manifest/site"
    mkdir -p "$MANIFEST_DIR"
    MANIFEST_PATH="$MANIFEST_DIR/clustereye-agent.xml"
    cat > "$MANIFEST_PATH" << EOF
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type='manifest' name='clustereye-agent'>
  <service name='site/clustereye-agent' type='service' version='1'>
    <create_default_instance enabled='false'/>
    <single_instance/>
    <dependency name='network' grouping='require_all' restart_on='none' type='service'>
      <service_fmri value='svc:/milestone/network:default'/>
    </dependency>
    <exec_method type='method' name='start' exec='$METHOD_SCRIPT start' timeout_seconds='30'>
      <method_context>
        <method_credential user='root' group='root'/>
      </method_context>
    </exec_method>
    <exec_method type='method' name='stop' exec=':kill' timeout_seconds='30'/>
    <property_group name='startd' type='framework'>
      <propval name='duration' type='astring' value='child'/>
      <propval name='ignore_error' type='astring' value='core,signal'/>
    </property_group>
    <template>
      <common_name><loctext xml:lang='C'>ClusterEye Agent</loctext></common_name>
    </template>
  </service>
</service_bundle>
EOF

    # Manifest'i SMF'ye import et
    if command -v svccfg >/dev/null 2>&1; then
        svccfg import "$MANIFEST_PATH"
    else
        echo -e "${YELLOW}Uyarı: svccfg bulunamadı; manifest dosyası yazıldı ama import edilmedi.${NC}"
    fi

    echo -e "\n${GREEN}Kurulum tamamlandı!${NC}"
    echo -e "\n${YELLOW}Önemli:${NC}"
    echo "1. Yapılandırma dosyasını düzenleyin:"
    echo "   sudo vi $INSTALL_DIR/agent.yml"
    echo -e "\n2. Servisi başlatın:"
    echo "   sudo svcadm enable site/clustereye-agent"
    echo -e "\n3. Servis durumunu kontrol edin:"
    echo "   svcs -l site/clustereye-agent"
    echo -e "\n4. Logları izleyin:"
    echo "   tail -f $INSTALL_DIR/agent.log"
    echo "   svcs -x site/clustereye-agent     # hata varsa detay"
fi
