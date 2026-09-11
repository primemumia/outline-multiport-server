#!/bin/bash
#
# shadowsocks-libev server installer (Outline install_server.sh benzeri)
#
# Kullanım:
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/primemumia/outline-multiport-server/main/server/install_scripts/install_server.sh)"
#
# veya:
#   curl -fsSL ... | sudo bash
#
# Ortam değişkenleri:
#   LIBEV_REPO          GitHub repo (varsayilan: primemumia/outline-multiport-server)
#   LIBEV_BRANCH        Dal adi (varsayilan: main)
#   LIBEV_INSTALL_DIR   Kurulum kok dizini (varsayilan: /opt/libev-server)
#   LIBEV_WORKDIR       ss-manager workdir (varsayilan: /var/lib/shadowsocks-manager)
#   LIBEV_PORT_START    Port havuzu baslangic (444)
#   LIBEV_PORT_END      Port havuzu bitis (999)
#   LIBEV_MULTI_PORT    Coklu cihaz portu (varsayilan: 443, IP kilidi yok)
#   LIBEV_SERVER_NAME   Bildirimlerde gorunecek sunucu adi (istege bagli)
#   TELECOM_TARGETS      Virgulle ayrilmis uc erisim testi hedefi
#   TELECOM_INTERVAL     Test araligi saniye (varsayilan: 60)
#   TELECOM_STATUS_FILE  Gozcu durum dosyasi (API /server buradan okur)
#
# Bayraklar:
#   --hostname HOST     Sunucu public IP veya domain
#   --api-port PORT     ss-api HTTP portu (varsayilan: 8087, ic ag)
#   --api-tls-port PORT Dis HTTPS API portu (varsayilan: 55555)
#   LIBEV_API_TLS_PORT ortam degiskeni ile de ayarlanabilir
#   --manager-port PORT (eski) UDP yerine unix socket kullanilir, yok sayilir
#   --server-name NAME  API /server icinde gorunecek sunucu adi
#   --bot-url URL       (eski, kullanilmaz; durum API uzerinden okunur)
#   --local             GitHub yerine yerel server/ dizinini kullan (out.sh ile)
#   -h, --help          Yardim

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=l
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_INPUT=1
export PIP_PROGRESS_BAR=off

readonly LIBEV_REPO="${LIBEV_REPO:-primemumia/outline-multiport-server}"
readonly LIBEV_BRANCH="${LIBEV_BRANCH:-main}"
readonly LIBEV_INSTALL_DIR="${LIBEV_INSTALL_DIR:-/opt/libev-server}"
readonly LIBEV_WORKDIR="${LIBEV_WORKDIR:-/var/lib/shadowsocks-manager}"
readonly LIBEV_SS_API_DIR="${LIBEV_SS_API_DIR:-/opt/ss-api}"
readonly LIBEV_PORT_START="${LIBEV_PORT_START:-444}"
readonly LIBEV_PORT_END="${LIBEV_PORT_END:-999}"
readonly MANAGER_SOCKET="${MANAGER_SOCKET:-${LIBEV_WORKDIR}/manager.sock}"
readonly SSL_DIR="/etc/libev/ssl"

readonly TELECOM_TARGETS="${TELECOM_TARGETS:-https://telecom.tm,https://astu.tm,https://e.gov.tm}"
readonly TELECOM_CONFIG="/etc/libev/telecom.json"
readonly TELECOM_STATUS_FILE="${TELECOM_STATUS_FILE:-/etc/libev/telecom_status.json}"
readonly TELECOM_WATCH_SCRIPT="${LIBEV_SS_API_DIR}/telecom_watch.py"
readonly TELECOM_INTERVAL="${TELECOM_INTERVAL:-60}"

# Coklu cihaz (443) portu IP-limitinden muaftir. Tek cihaz limiti sadece
# LIBEV_PORT_START..LIBEV_PORT_END araligina (444-999) uygulanir.
readonly LIBEV_MULTI_PORT="${LIBEV_MULTI_PORT:-443}"

# archive.ubuntu.com/security.ubuntu.com bazi aglarda engelli/yavas olabilir;
# bu mirror erisim testinden gecerse apt kaynaklari buna yonlendirilir.
readonly APT_MIRROR_HOST="${LIBEV_APT_MIRROR:-mirror.yandex.ru}"

FLAGS_HOSTNAME=""
FLAGS_API_PORT=0
FLAGS_API_TLS_PORT=0
FLAGS_MANAGER_PORT=0
FLAGS_LOCAL=0
FLAGS_BOT_URL="${LIBEV_BOT_URL:-}"
FLAGS_SERVER_NAME="${LIBEV_SERVER_NAME:-}"
FLAGS_PATCH_TELECOM=0
LIBEV_SOURCE_DIR="${LIBEV_SOURCE_DIR:-}"
PREBUILT_BIN_DIR=""

FULL_LOG="$(mktemp -t libev_install_logXXXXXX)"
LAST_ERROR="$(mktemp -t libev_install_errXXXXXX)"
readonly FULL_LOG LAST_ERROR
readonly STEP_LINE_WIDTH=52
readonly STEP_MSG_MAX=34
readonly STEP_STATUS_WIDTH=7

function print_step_line() {
    local msg="$1"
    local status="$2"
    if (( ${#msg} > STEP_MSG_MAX )); then
        msg="${msg:0:$(( STEP_MSG_MAX - 3 ))}..."
    fi
    local prefix="> ${msg}"
    local status_pad
    status_pad="$(printf '%-*s' "${STEP_STATUS_WIDTH}" "${status}")"
    local -i dots=$(( STEP_LINE_WIDTH - ${#prefix} - STEP_STATUS_WIDTH - 1 ))
    if (( dots < 2 )); then
        dots=2
    fi
    local dotstr=""
    local _i
    for ((_i = 0; _i < dots; _i++)); do
        dotstr+="."
    done
    local line="${prefix} ${dotstr} ${status_pad}"
    while (( ${#line} < STEP_LINE_WIDTH )); do
        line+=" "
    done
    if [[ "${status}" == "WAITING" ]]; then
        printf '\r%s' "${line}"
    else
        printf '\r%s\n' "${line}"
    fi
}

function display_usage() {
    cat <<'EOF'
shadowsocks-libev Server Installer

Kullanim:
  sudo bash install_server.sh [--hostname HOST] [--api-port PORT] [--manager-port PORT] [--bot-url URL] [--server-name NAME]

Ornek (GitHub'dan):
  sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/primemumia/outline-multiport-server/main/server/install_scripts/install_server.sh)"

Ornek (bot bildirimi ile):
  sudo bash install_server.sh --bot-url https://bot.example.com --server-name "TM-1"

Ortam:
  LIBEV_REPO=primemumia/outline-multiport-server
  LIBEV_BRANCH=main
    TELECOM_TARGETS=https://telecom.tm,https://astu.tm,https://e.gov.tm
  TELECOM_INTERVAL=60
EOF
}

function log_error() {
    echo -e "\033[0;31m$1\033[0m" >&2
    echo "$1" >> "${FULL_LOG}"
}

function log_start_step() {
    :
}

function log_command() {
    local rc=0
    "$@" >> "${FULL_LOG}" 2>> "${FULL_LOG}" </dev/null || rc=$?
    if (( rc != 0 )); then
        {
            echo "--- komut basarisiz (cikis ${rc}): $* ---"
            tail -30 "${FULL_LOG}"
        } >> "${LAST_ERROR}"
    fi
    return "${rc}"
}

function wait_for_apt_lock() {
    # Taze acilan VPS'lerde unattended-upgrades/apt-daily dpkg kilidini tutabilir.
    if ! command_exists fuser; then
        return 0
    fi
    local -i waited=0
    local -ir max_wait=90
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if (( waited == 0 )); then
            echo "apt/dpkg kilidi baska bir islem tarafindan tutuluyor (unattended-upgrades olabilir), bekleniyor..." >> "${FULL_LOG}"
        fi
        if (( waited >= max_wait )); then
            log_error "apt/dpkg kilidi ${max_wait}s sonra hala acik degil. Kontrol edin: ps aux | grep -E 'apt|dpkg|unattended'"
            return 1
        fi
        sleep 3
        waited+=3
    done
    return 0
}

function setup_apt_mirror() {
    # archive.ubuntu.com/security.ubuntu.com bazi aglarda sessizce engelli
    # olabilir (apt-get update sonsuza kadar takilir). Once alternatif mirror
    # erisilebilir mi diye hizli test edilir; erisilebilirse apt kaynaklari
    # buna yonlendirilir. Erisilemezse hicbir sey degistirilmez.
    if ! curl --silent --show-error --fail --ipv4 --connect-timeout 5 --max-time 8 \
        -o /dev/null "http://${APT_MIRROR_HOST}/ubuntu/"; then
        echo "apt mirror ${APT_MIRROR_HOST} erisilemedi; varsayilan kaynaklar korunuyor." >> "${FULL_LOG}"
        return 0
    fi

    local changed=0
    local sources_deb822="/etc/apt/sources.list.d/ubuntu.sources"
    local sources_list="/etc/apt/sources.list"
    local target

    for target in "${sources_deb822}" "${sources_list}"; do
        [[ -f "${target}" ]] || continue
        grep -q 'archive\.ubuntu\.com\|security\.ubuntu\.com' "${target}" 2>/dev/null || continue
        cp -a "${target}" "${target}.bak.$(date +%s)" 2>/dev/null || true
        sed -i \
            -e "s#http://archive\.ubuntu\.com/ubuntu#http://${APT_MIRROR_HOST}/ubuntu#g" \
            -e "s#https://archive\.ubuntu\.com/ubuntu#https://${APT_MIRROR_HOST}/ubuntu#g" \
            -e "s#http://security\.ubuntu\.com/ubuntu#http://${APT_MIRROR_HOST}/ubuntu#g" \
            -e "s#https://security\.ubuntu\.com/ubuntu#https://${APT_MIRROR_HOST}/ubuntu#g" \
            "${target}"
        changed=1
    done

    if (( changed == 1 )); then
        echo "apt kaynaklari ${APT_MIRROR_HOST} mirror'una yonlendirildi." >> "${FULL_LOG}"
    else
        echo "apt kaynak dosyasinda archive/security.ubuntu.com bulunamadi; degistirilmedi." >> "${FULL_LOG}"
    fi
    return 0
}

function apt_update() {
    wait_for_apt_lock || return 1
    apt-get update -qq \
        -o Acquire::http::Timeout=15 \
        -o Acquire::https::Timeout=15 \
        -o Acquire::Retries=2 </dev/null
}

function apt_install() {
    wait_for_apt_lock || return 1
    apt-get install -qq -y \
        -o Dpkg::Use-Pty=0 \
        -o Dpkg::Progress-Fancy=0 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        -o Acquire::http::Timeout=15 \
        -o Acquire::https::Timeout=15 \
        -o Acquire::Retries=2 \
        "$@" </dev/null
}

function pip_install_quiet() {
    if pip3 install -q --disable-pip-version-check --no-warn-script-location \
        -r "${LIBEV_SS_API_DIR}/requirements.txt" </dev/null 2>&1; then
        return 0
    fi
    pip3 install -q --disable-pip-version-check --no-warn-script-location \
        --break-system-packages -r "${LIBEV_SS_API_DIR}/requirements.txt" </dev/null 2>&1 || \
        apt_install python3-aiohttp
}

function run_step() {
    local -r msg="$1"
    shift 1
    print_step_line "${msg}" "WAITING"
    if log_command "$@"; then
        print_step_line "${msg}" "OK"
    else
        print_step_line "${msg}" "FAIL"
        return 1
    fi
}

function command_exists() {
    command -v "$@" >/dev/null 2>&1
}

function fetch() {
    curl --silent --show-error --fail --ipv4 --connect-timeout 8 --max-time 20 "$@"
}

function safe_base64() {
    base64 -w 0 2>/dev/null | tr '/+' '_-' | tr -d '='
}

function load_existing_api_secret() {
    local line secret
    if [[ -f "${LIBEV_INSTALL_DIR}/access.txt" ]]; then
        line="$(grep -m1 '^internalApiUrl:' "${LIBEV_INSTALL_DIR}/access.txt" 2>/dev/null || true)"
        if [[ -n "${line}" ]]; then
            secret="${line#*://*/}"
            secret="${secret%%[[:space:]]*}"
            if [[ -n "${secret}" ]]; then
                echo "${secret}"
                return 0
            fi
        fi
    fi
    if [[ -f /etc/systemd/system/ss-api.service ]]; then
        secret="$(sed -n 's/.*--api-secret \([^[:space:]]*\).*/\1/p' /etc/systemd/system/ss-api.service | head -1)"
        if [[ -n "${secret}" ]]; then
            echo "${secret}"
            return 0
        fi
    fi
    return 1
}

function generate_api_secret() {
    if [[ -n "${LIBEV_API_SECRET:-}" ]]; then
        readonly LIBEV_API_SECRET
        return 0
    fi
    if secret="$(load_existing_api_secret)"; then
        LIBEV_API_SECRET="${secret}"
        echo "Mevcut API secret korunuyor (yeniden kurulum)." >> "${FULL_LOG}"
        readonly LIBEV_API_SECRET
        return 0
    fi
    LIBEV_API_SECRET="$(head -c 24 /dev/urandom | safe_base64)"
    readonly LIBEV_API_SECRET
}

function require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Root olarak calistirin: sudo bash install_server.sh"
        exit 1
    fi
}

function detect_public_ip() {
    local -ar urls=(
        'https://icanhazip.com/'
        'https://ipinfo.io/ip'
        'https://domains.google.com/checkip'
    )
    local ip url
    for url in "${urls[@]}"; do
        ip="$(fetch "${url}" | tr -d '[:space:]')" && [[ -n "${ip}" ]] && {
            PUBLIC_HOSTNAME="${ip}"
            return 0
        }
    done
    log_error "Public IP tespit edilemedi. --hostname kullanin."
    return 1
}

function refresh_server_ip() {
    local detected
    detected="$(fetch 'https://icanhazip.com/' 2>/dev/null | tr -d '[:space:]')" || detected=""
    [[ -n "${detected}" ]] || return 0
    if [[ "${detected}" != "${PUBLIC_HOSTNAME}" ]]; then
        echo "Public IP yenilendi: ${PUBLIC_HOSTNAME} -> ${detected}" >> "${FULL_LOG}"
        PUBLIC_HOSTNAME="${detected}"
    fi
}

function install_dependencies() {
    apt_update
    apt_install \
        python3 python3-pip curl ca-certificates tar \
        rsync nginx openssl libcap2-bin iproute2 \
        libev4 libpcre2-8-0 libc-ares2 libsodium23 libmbedcrypto7 \
        2>>"${FULL_LOG}" || apt_install \
        python3 python3-pip curl ca-certificates tar \
        rsync nginx openssl libcap2-bin iproute2 \
        libev4 libpcre2-8-0 libc-ares2 libsodium23 libmbedtls14 \
        2>>"${FULL_LOG}" || apt_install \
        python3 python3-pip curl ca-certificates tar \
        rsync nginx openssl libcap2-bin iproute2 \
        libev4 libpcre2-8-0 libc-ares2 libsodium23 libmbedcrypto3
}

function host_glibc_version() {
    getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}'
}

function detect_host_os_tag() {
    local os_id="" os_ver="" glibc="" ver_major=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_ver="${VERSION_ID:-}"
    fi

    if [[ "${os_id}" == "ubuntu" ]]; then
        ver_major="${os_ver%%.*}"
        case "${ver_major}" in
            26) echo "ubuntu26.04" ; return 0 ;;
            24|25) echo "ubuntu24.04" ; return 0 ;;
            22) echo "ubuntu22.04" ; return 0 ;;
            20) echo "ubuntu20.04" ; return 0 ;;
        esac
    fi

    glibc="$(host_glibc_version)"
    case "${glibc}" in
        2.4[1-9]*|2.[5-9]*|3.*) echo "ubuntu26.04" ;;
        2.38|2.39|2.40) echo "ubuntu24.04" ;;
        2.35|2.36|2.37) echo "ubuntu22.04" ;;
        2.3[0-4]*) echo "ubuntu20.04" ;;
        *) echo "auto" ;;
    esac
}

function prebuilt_candidate_dirs() {
    local base="$1"
    local tag="$2"

    case "${tag}" in
        ubuntu26.04)
            printf '%s\n' \
                "${base}/ubuntu26.04" \
                "${base}/glibc2.41" \
                "${base}/ubuntu24.04" \
                "${base}/glibc2.38" \
                "${base}/ubuntu22.04" \
                "${base}/glibc2.35" \
                "${base}"
            ;;
        ubuntu24.04)
            printf '%s\n' \
                "${base}/ubuntu24.04" \
                "${base}/glibc2.38" \
                "${base}/ubuntu22.04" \
                "${base}/glibc2.35" \
                "${base}/ubuntu20.04" \
                "${base}/glibc2.31" \
                "${base}"
            ;;
        ubuntu22.04)
            printf '%s\n' \
                "${base}/ubuntu22.04" \
                "${base}/glibc2.35" \
                "${base}/ubuntu20.04" \
                "${base}/glibc2.31" \
                "${base}"
            ;;
        ubuntu20.04)
            printf '%s\n' \
                "${base}/ubuntu20.04" \
                "${base}/glibc2.31" \
                "${base}/ubuntu22.04" \
                "${base}/glibc2.35" \
                "${base}"
            ;;
        *)
            printf '%s\n' \
                "${base}/ubuntu26.04" \
                "${base}/ubuntu24.04" \
                "${base}/glibc2.38" \
                "${base}/ubuntu22.04" \
                "${base}/glibc2.35" \
                "${base}/ubuntu20.04" \
                "${base}/glibc2.31" \
                "${base}"
            ;;
    esac
}

function binary_is_compatible() {
    local bin="$1"
    local ldd_out
    [[ -x "${bin}" ]] || return 1
    ldd_out="$(ldd "${bin}" 2>&1)" || true
    if echo "${ldd_out}" | grep -q "not found"; then
        return 1
    fi
    return 0
}

function verify_binary_deps() {
    local missing
    missing="$(ldd /usr/local/bin/ss-manager 2>/dev/null | grep 'not found' || true)"
    if [[ -n "${missing}" ]]; then
        log_error "ss-manager kutuphane eksik:${missing}"
        if echo "${missing}" | grep -q 'GLIBC_'; then
            log_error "Prebuilt binary sunucu glibc surumu ile uyumsuz (sunucu: $(host_glibc_version))."
            log_error "Repo icine bu Ubuntu icin ss-server/ss-manager koyun: bin/${MACHINE_TYPE}/ubuntuXX.04/"
        else
            log_error "apt install libev4 libpcre2-8-0 libc-ares2 libsodium23 libmbedcrypto7"
        fi
        return 1
    fi
    return 0
}

function cache_prebuilt_from_dir() {
    local src="$1"
    PREBUILT_BIN_DIR="${LIBEV_INSTALL_DIR}/prebuilt/${MACHINE_TYPE}"
    mkdir -p "${PREBUILT_BIN_DIR}"
    install -m 755 "${src}/ss-server" "${PREBUILT_BIN_DIR}/ss-server"
    install -m 755 "${src}/ss-manager" "${PREBUILT_BIN_DIR}/ss-manager"
}

function try_cache_prebuilt() {
    local base="$1"
    local tag candidate seen=""
    tag="$(detect_host_os_tag)"
    echo "OS tespiti: ${tag} (glibc $(host_glibc_version))" >> "${FULL_LOG}"

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if [[ " ${seen} " == *" ${candidate} "* ]]; then
            continue
        fi
        seen="${seen} ${candidate}"
        if [[ -f "${candidate}/ss-server" && -f "${candidate}/ss-manager" ]]; then
            if binary_is_compatible "${candidate}/ss-manager"; then
                echo "Uyumlu prebuilt: ${candidate}" >> "${FULL_LOG}"
                cache_prebuilt_from_dir "${candidate}"
                return 0
            fi
            echo "Prebuilt glibc uyumsuz atlandi: ${candidate}" >> "${FULL_LOG}"
        fi
    done < <(prebuilt_candidate_dirs "${base}" "${tag}")

    return 1
}

function patch_ss_api_multi_port() {
    # ss-api key_store.py: coklu cihaz portunu (443) izinli aralik disinda olsa
    # bile kabul et.
    local ks="${LIBEV_SS_API_DIR}/key_store.py"
    if [[ ! -f "${ks}" ]]; then
        echo "key_store.py bulunamadi, coklu-port yamasi atlandi: ${ks}" >> "${FULL_LOG}"
        return 0
    fi
    KS_PATH="${ks}" python3 - <<'PYEOF'
import os

path = os.environ["KS_PATH"]
with open(path, "r", encoding="utf-8") as fh:
    src = fh.read()

if "_multi_ports(" in src:
    print("key_store.py zaten yamali; atlaniyor.")
    raise SystemExit(0)

helper = (
    "def _multi_ports():\n"
    "    raw = os.environ.get(\"LIBEV_MULTI_PORTS\", \"443\")\n"
    "    result = set()\n"
    "    for part in raw.split(\",\"):\n"
    "        part = part.strip()\n"
    "        if part.isdigit():\n"
    "            result.add(int(part))\n"
    "    return result\n"
    "\n"
    "\n"
    "def generate_password"
)
if "import os\n" not in src:
    src = src.replace("import json\n", "import json\nimport os\n", 1)
src = src.replace("def generate_password", helper, 1)

old_check = (
    "            if not (self.port_start <= preferred <= self.port_end):\n"
    "                raise ValueError(f\"Port {preferred} aralık dışında ({self.port_start}-{self.port_end})\")\n"
)
new_check = (
    "            if preferred not in _multi_ports() and not (self.port_start <= preferred <= self.port_end):\n"
    "                raise ValueError(f\"Port {preferred} aralık dışında ({self.port_start}-{self.port_end})\")\n"
)
if old_check in src:
    src = src.replace(old_check, new_check, 1)
else:
    raise SystemExit("HATA: allocate_port araligi bulunamadi (key_store.py degismis olabilir)")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)
print("key_store.py yamalandi (443 izinli).")
PYEOF
    echo "key_store.py coklu-port yamasi uygulandi (${LIBEV_MULTI_PORT})." >> "${FULL_LOG}"
}

function patch_ss_api_telecom_status() {
    # ss_api.py: /server (ve /server-status) telecom.tm durumunu dosyadan okusun.
    local api_py="${LIBEV_SS_API_DIR}/ss_api.py"
    if [[ ! -f "${api_py}" ]]; then
        echo "ss_api.py bulunamadi, telecom yamasi atlandi: ${api_py}" >> "${FULL_LOG}"
        return 0
    fi
    API_PY="${api_py}" STATUS_FILE="${TELECOM_STATUS_FILE}" python3 - <<'PYEOF'
import os

path = os.environ["API_PY"]
status_file = os.environ.get("STATUS_FILE") or "/etc/libev/telecom_status.json"
with open(path, "r", encoding="utf-8") as fh:
    src = fh.read()

if "_read_telecom_status" in src:
    if "telecomAttemptResults" in src:
        print("ss_api.py telecom yamasi zaten guncel; atlaniyor.")
        raise SystemExit(0)
    old_status_fields = (
        '            "telecomServerName": data.get("server_name") or "",\n'
        "        }\n"
    )
    new_status_fields = (
        '            "telecomServerName": data.get("server_name") or "",\n'
        '            "telecomAttemptResults": data.get("attempt_results") or [],\n'
        '            "telecomSuccessfulAttempts": data.get("successful_attempts", 0),\n'
        '            "telecomFailedAttempts": data.get("failed_attempts", 0),\n'
        "        }\n"
    )
    if old_status_fields not in src:
        raise SystemExit("HATA: Eski telecom API yamasi guncellenemedi")
    src = src.replace(old_status_fields, new_status_fields, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("ss_api.py telecom yamasi uc deneme alanlariyla guncellendi.")
    raise SystemExit(0)

if "import os\n" not in src:
    src = src.replace("import json\n", "import json\nimport os\n", 1)

old = (
    "    async def handle_server_info(self, request: web.Request) -> web.Response:\n"
    "        await self._require_auth(request)\n"
    "        return web.json_response(\n"
    "            {\n"
    '                "name": "shadowsocks-libev",\n'
    '                "serverIp": self.keys.server_ip,\n'
    '                "managerAddress": self.keys.client.manager_address,\n'
    '                "method": DEFAULT_METHOD,\n'
    "            }\n"
    "        )\n"
)
new = (
    "    def _read_telecom_status(self):\n"
    "        path = os.environ.get(\"TELECOM_STATUS_FILE\", %r)\n"
    "        try:\n"
    "            with open(path, \"r\", encoding=\"utf-8\") as fh:\n"
    "                data = json.load(fh)\n"
    "        except Exception:\n"
    "            return None\n"
    "        if not isinstance(data, dict):\n"
    "            return None\n"
    "        status = data.get(\"status\")\n"
    "        if status not in (\"online\", \"blocked\"):\n"
    "            return None\n"
    "        return {\n"
    "            \"telecomStatus\": status,\n"
    "            \"telecomHttpCode\": data.get(\"http_code\", 0),\n"
    "            \"telecomTarget\": data.get(\"target\") or \"https://telecom.tm\",\n"
    "            \"telecomDetail\": data.get(\"detail\") or \"\",\n"
    "            \"telecomCheckedAt\": data.get(\"checked_at\") or 0,\n"
    "            \"telecomServerName\": data.get(\"server_name\") or \"\",\n"
    "            \"telecomAttemptResults\": data.get(\"attempt_results\") or [],\n"
    "            \"telecomSuccessfulAttempts\": data.get(\"successful_attempts\", 0),\n"
    "            \"telecomFailedAttempts\": data.get(\"failed_attempts\", 0),\n"
    "        }\n"
    "\n"
    "    async def handle_server_info(self, request: web.Request) -> web.Response:\n"
    "        await self._require_auth(request)\n"
    "        payload = {\n"
    "            \"name\": \"shadowsocks-libev\",\n"
    "            \"serverIp\": self.keys.server_ip,\n"
    "            \"managerAddress\": self.keys.client.manager_address,\n"
    "            \"method\": DEFAULT_METHOD,\n"
    "        }\n"
    "        extra = self._read_telecom_status()\n"
    "        if extra:\n"
    "            payload.update(extra)\n"
    "        return web.json_response(payload)\n"
    "\n"
    "    async def handle_telecom_status(self, request: web.Request) -> web.Response:\n"
    "        await self._require_auth(request)\n"
    "        extra = self._read_telecom_status()\n"
    "        if not extra:\n"
    "            return web.json_response({\"telecomStatus\": None}, status=200)\n"
    "        return web.json_response(extra)\n"
) % status_file
if old not in src:
    raise SystemExit("HATA: handle_server_info blogu bulunamadi (ss_api.py degismis olabilir)")
src = src.replace(old, new, 1)

old_route = (
    "        app.router.add_get(f\"{secret}/server\", self.handle_server_info)\n"
    "        return app\n"
)
new_route = (
    "        app.router.add_get(f\"{secret}/server\", self.handle_server_info)\n"
    "        app.router.add_get(f\"{secret}/server-status\", self.handle_telecom_status)\n"
    "        return app\n"
)
if old_route not in src:
    raise SystemExit("HATA: /server route bulunamadi (ss_api.py degismis olabilir)")
src = src.replace(old_route, new_route, 1)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(src)
print("ss_api.py yamalandi (telecomStatus /server).")
PYEOF
    echo "ss_api.py telecom durum yamasi uygulandi (${TELECOM_STATUS_FILE})." >> "${FULL_LOG}"
}

function fetch_server_sources() {
    mkdir -p "${LIBEV_INSTALL_DIR}" "${LIBEV_WORKDIR}" "${LIBEV_SS_API_DIR}" /etc/libev

    if (( FLAGS_LOCAL == 1 )); then
        local src_root="${LIBEV_SOURCE_DIR}"
        local script_dir=""
        if [[ -z "${src_root}" ]]; then
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [[ -d "${script_dir}/ss-api" ]]; then
                src_root="${script_dir}"
            elif [[ -d "${script_dir}/../ss-api" ]]; then
                src_root="$(cd "${script_dir}/.." && pwd)"
            elif [[ -d "${script_dir}/../server/ss-api" ]]; then
                src_root="$(cd "${script_dir}/../server" && pwd)"
            else
                src_root="${script_dir}"
            fi
        fi
        if [[ ! -d "${src_root}/ss-api" ]]; then
            log_error "Yerel ss-api bulunamadi: ${src_root}/ss-api"
            return 1
        fi
        if ! try_cache_prebuilt "${src_root}/bin/${MACHINE_TYPE}"; then
            log_error "Uyumlu prebuilt binary yok: ${src_root}/bin/${MACHINE_TYPE}/ (OS: $(detect_host_os_tag))"
            return 1
        fi
        rsync -a "${src_root}/ss-api/" "${LIBEV_SS_API_DIR}/"
        if [[ -f "${src_root}/install_scripts/uninstall_server.sh" ]]; then
            install -m 755 "${src_root}/install_scripts/uninstall_server.sh" "${LIBEV_SS_API_DIR}/uninstall_server.sh"
        elif [[ -f "${src_root}/uninstall_server.sh" ]]; then
            install -m 755 "${src_root}/uninstall_server.sh" "${LIBEV_SS_API_DIR}/uninstall_server.sh"
        fi
        return 0
    fi

    local clone_dir archive_url
    clone_dir="$(mktemp -d /tmp/libev-src.XXXXXX)"
    archive_url="https://github.com/${LIBEV_REPO}/archive/refs/heads/${LIBEV_BRANCH}.tar.gz"
    echo "Repo arsivi indiriliyor: ${archive_url}" >> "${FULL_LOG}"

    if ! curl --silent --show-error --fail --location --ipv4 \
        --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 3 "${archive_url}" \
        | tar -xz -C "${clone_dir}" --strip-components=1 >> "${FULL_LOG}" 2>&1; then
        rm -rf "${clone_dir}"
        log_error "Repo indirilemedi (baglanti zaman asimina ugramis olabilir): ${archive_url}"
        return 1
    fi

    local root="${clone_dir}"
    if [[ -d "${clone_dir}/server/ss-api" ]]; then
        root="${clone_dir}/server"
    elif [[ ! -d "${clone_dir}/ss-api" ]]; then
        log_error "Repo yapisi hatali: ss-api bulunamadi (${LIBEV_REPO})"
        rm -rf "${clone_dir}"
        return 1
    fi

    if ! try_cache_prebuilt "${root}/bin/${MACHINE_TYPE}"; then
        log_error "Uyumlu prebuilt binary yok (${MACHINE_TYPE}, OS: $(detect_host_os_tag), glibc $(host_glibc_version))."
        log_error "Beklenen yol: bin/${MACHINE_TYPE}/ubuntu20.04|ubuntu22.04|ubuntu24.04|ubuntu26.04/ss-server"
        rm -rf "${clone_dir}"
        return 1
    fi

    rsync -a "${root}/ss-api/" "${LIBEV_SS_API_DIR}/"
    if [[ -f "${root}/install_scripts/uninstall_server.sh" ]]; then
        install -m 755 "${root}/install_scripts/uninstall_server.sh" "${LIBEV_SS_API_DIR}/uninstall_server.sh"
    elif [[ -f "${root}/uninstall_server.sh" ]]; then
        install -m 755 "${root}/uninstall_server.sh" "${LIBEV_SS_API_DIR}/uninstall_server.sh"
    fi

    rm -rf "${clone_dir}"
}

function install_shadowsocks_binaries() {
    if [[ -z "${PREBUILT_BIN_DIR}" || ! -x "${PREBUILT_BIN_DIR}/ss-server" || ! -x "${PREBUILT_BIN_DIR}/ss-manager" ]]; then
        log_error "Prebuilt binary bulunamadi. Kurulum kaynaktan derlemez; repo icindeki hazir dosyalari kullanir."
        log_error "Koyun: bin/${MACHINE_TYPE}/$(detect_host_os_tag)/ss-server ve ss-manager"
        return 1
    fi

    install -m 755 "${PREBUILT_BIN_DIR}/ss-server" /usr/local/bin/ss-server
    install -m 755 "${PREBUILT_BIN_DIR}/ss-manager" /usr/local/bin/ss-manager
    verify_binary_deps
}

function install_python_deps() {
    pip_install_quiet
    chmod +x "${LIBEV_SS_API_DIR}/libev" "${LIBEV_SS_API_DIR}/libev-cli.py"
    local uninstall_src=""
    if [[ -f "${LIBEV_SS_API_DIR}/../install_scripts/uninstall_server.sh" ]]; then
        uninstall_src="${LIBEV_SS_API_DIR}/../install_scripts/uninstall_server.sh"
    elif [[ -f "/opt/ss-api/uninstall_server.sh" ]]; then
        uninstall_src="/opt/ss-api/uninstall_server.sh"
    fi
    if [[ -f "${LIBEV_SS_API_DIR}/uninstall_server.sh" ]]; then
        chmod +x "${LIBEV_SS_API_DIR}/uninstall_server.sh"
    elif [[ -n "${uninstall_src}" ]]; then
        install -m 755 "${uninstall_src}" "${LIBEV_SS_API_DIR}/uninstall_server.sh"
    fi
    cat > /usr/local/bin/libev <<EOF
#!/bin/bash
exec python3 ${LIBEV_SS_API_DIR}/libev-cli.py "\$@"
EOF
    chmod +x /usr/local/bin/libev
    patch_ss_api_multi_port
    patch_ss_api_telecom_status
}

function configure_system_limits() {
    cat > /etc/security/limits.d/shadowsocks-libev.conf <<'EOF'
root soft nofile 65535
root hard nofile 65535
* soft nofile 65535
* hard nofile 65535
EOF

    cat > /etc/sysctl.d/99-shadowsocks-libev.conf <<'EOF'
fs.file-max = 65535
EOF
    sysctl -p /etc/sysctl.d/99-shadowsocks-libev.conf >> "${FULL_LOG}" 2>&1 || true

    mkdir -p /etc/systemd/system/shadowsocks-manager.service.d
    cat > /etc/systemd/system/shadowsocks-manager.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65535
EOF

    mkdir -p /etc/systemd/system/ss-api.service.d
    cat > /etc/systemd/system/ss-api.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65535
EOF

    echo "Sistem limitleri: nofile=65535, fs.file-max=65535" >> "${FULL_LOG}"
}

function write_configs() {
    rm -f "${MANAGER_SOCKET}"

    cat > /etc/libev/cli.json <<EOF
{
  "manager_address": "${MANAGER_SOCKET}",
  "server_ip": "${PUBLIC_HOSTNAME}",
  "port_store": "${LIBEV_WORKDIR}/ports.json",
  "port_range": {
    "start": ${LIBEV_PORT_START},
    "end": ${LIBEV_PORT_END}
  }
}
EOF
    chmod 600 /etc/libev/cli.json

    cat > /etc/systemd/system/shadowsocks-manager.service <<EOF
[Unit]
Description=Shadowsocks Libev Manager (ss-manager)
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
StateDirectory=shadowsocks-manager
RuntimeDirectory=shadowsocks-manager
ExecStartPre=/bin/mkdir -p ${LIBEV_WORKDIR}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=SS_IPLOCK_MIN=${LIBEV_PORT_START}
Environment=SS_IPLOCK_MAX=${LIBEV_PORT_END}
ExecStart=/usr/local/bin/ss-manager -u -n 65535 --executable /usr/local/bin/ss-server --manager-address ${MANAGER_SOCKET} --workdir ${LIBEV_WORKDIR} -s 0.0.0.0 -m chacha20-ietf-poly1305
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/ss-api.service <<EOF
[Unit]
Description=Shadowsocks Libev HTTP API
After=network.target shadowsocks-manager.service
Requires=shadowsocks-manager.service

[Service]
Type=simple
User=root
LimitNOFILE=65535
WorkingDirectory=${LIBEV_SS_API_DIR}
Environment=LIBEV_MULTI_PORTS=${LIBEV_MULTI_PORT}
Environment=TELECOM_STATUS_FILE=${TELECOM_STATUS_FILE}
ExecStart=/usr/bin/python3 ${LIBEV_SS_API_DIR}/ss_api.py --host 127.0.0.1 --port ${API_PORT} --manager-address ${MANAGER_SOCKET} --server-ip ${PUBLIC_HOSTNAME} --api-secret ${LIBEV_API_SECRET} --port-store ${LIBEV_WORKDIR}/ports.json
StandardOutput=null
StandardError=journal
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    # API secret'i dosyada tasidigi icin sadece root okuyabilsin
    chmod 600 /etc/systemd/system/ss-api.service
}

function configure_firewall() {
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        echo "UFW aktif; portlar aciliyor: ${API_TLS_PORT}/tcp, ${LIBEV_MULTI_PORT}/tcp+udp, ${LIBEV_PORT_START}-${LIBEV_PORT_END}/tcp+udp" >> "${FULL_LOG}"
        ufw allow "${API_TLS_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${LIBEV_MULTI_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${LIBEV_MULTI_PORT}/udp" >/dev/null 2>&1 || true
        ufw allow "${LIBEV_PORT_START}:${LIBEV_PORT_END}/tcp" >/dev/null 2>&1 || true
        ufw allow "${LIBEV_PORT_START}:${LIBEV_PORT_END}/udp" >/dev/null 2>&1 || true
    fi
}

function setup_api_tls() {
    mkdir -p "${SSL_DIR}"
    if [[ ! -f "${SSL_DIR}/cert.pem" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${SSL_DIR}/key.pem" \
            -out "${SSL_DIR}/cert.pem" \
            -subj "/CN=${PUBLIC_HOSTNAME}" >/dev/null 2>&1
    fi

    CERT_SHA256="$(openssl x509 -in "${SSL_DIR}/cert.pem" -outform DER | openssl dgst -sha256 | awk '{print toupper($2)}')"
    readonly CERT_SHA256

    PUBLIC_API_URL="https://${PUBLIC_HOSTNAME}:${API_TLS_PORT}/${LIBEV_API_SECRET}"
    readonly PUBLIC_API_URL

    cat > /etc/nginx/sites-available/libev-api <<EOF
server {
    listen ${API_TLS_PORT} ssl;
    listen [::]:${API_TLS_PORT} ssl;
    server_name _;

    ssl_certificate ${SSL_DIR}/cert.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;

    location / {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/libev-api /etc/nginx/sites-enabled/libev-api
    rm -f /etc/nginx/sites-enabled/default

    local nginx_test
    if ! nginx_test="$(nginx -t 2>&1)"; then
        log_error "nginx yapilandirmasi gecersiz (libev-api):"
        log_error "${nginx_test}"
        return 1
    fi

    systemctl enable nginx >/dev/null 2>&1
    if systemctl is-active --quiet nginx; then
        if ! systemctl reload nginx; then
            log_error "nginx reload basarisiz. journalctl -u nginx -n 30 --no-pager"
            return 1
        fi
    else
        if ! systemctl start nginx; then
            log_error "nginx baslatilamadi. journalctl -u nginx -n 30 --no-pager"
            return 1
        fi
    fi
    configure_firewall
}

function verify_public_api() {
    if curl -sfk --max-time 10 "https://127.0.0.1:${API_TLS_PORT}/${LIBEV_API_SECRET}/server" >/dev/null 2>&1; then
        return 0
    fi
    log_error "Genel HTTPS API (nginx, port ${API_TLS_PORT}) yanit vermiyor."
    log_error "Kontrol edin: systemctl status nginx / nginx -t / journalctl -u nginx -n 30"
    return 1
}

function start_services() {
    mkdir -p "${LIBEV_WORKDIR}"
    systemctl daemon-reload
    systemctl enable shadowsocks-manager ss-api
    systemctl restart shadowsocks-manager
    if ! systemctl is-active --quiet shadowsocks-manager; then
        journalctl -u shadowsocks-manager -n 25 --no-pager >> "${FULL_LOG}" 2>&1 || true
        log_error "shadowsocks-manager baslamadi: journalctl -u shadowsocks-manager -n 30 --no-pager"
        return 1
    fi
    sleep 2
    systemctl restart ss-api
    sleep 1
}

function wait_for_manager() {
    local -i i
    for i in $(seq 1 15); do
        if [[ -S "${MANAGER_SOCKET}" ]]; then
            return 0
        fi
        sleep 1
    done
    journalctl -u shadowsocks-manager -n 25 --no-pager >> "${FULL_LOG}" 2>&1 || true
    log_error "manager.sock yok (${MANAGER_SOCKET}). journalctl -u shadowsocks-manager -n 30"
    return 1
}

function sync_manager_ports() {
    python3 <<PYEOF
import sys
sys.path.insert(0, "${LIBEV_SS_API_DIR}")
from key_store import KeyManager

km = KeyManager.from_config("/etc/libev/cli.json")
km.client.ping()
result = km.sync_to_manager()
print(
    f"Sync: {result['added']} eklendi, "
    f"{result['already_active']} zaten vardi, toplam {result['total']}"
)
if result["errors"]:
    for err in result["errors"][:5]:
        print(
            f"  HATA port {err.get('port')}: {err.get('error')}",
            file=sys.stderr,
        )
    sys.exit(1)
PYEOF
}

function wait_for_api() {
    local -i i
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${API_PORT}/${LIBEV_API_SECRET}/server" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    log_error "ss-api hazir degil (port ${API_PORT})"
    return 1
}

function create_first_access_key() {
    FIRST_KEY_JSON="$(python3 <<PYEOF
import json
import sys
sys.path.insert(0, "${LIBEV_SS_API_DIR}")
from key_store import KeyManager

km = KeyManager.from_config("/etc/libev/cli.json")
try:
    result = km.add_key("default")
except ValueError:
    found = km.find_by_name("default")
    if not found:
        raise
    port, entry = found
    result = km.key_payload(port, entry)
print(json.dumps(result, ensure_ascii=False))
PYEOF
)"
    readonly FIRST_KEY_JSON
}

function verify_vpn_listening() {
    local port listening=0
    port="$(python3 <<PYEOF
import sys
sys.path.insert(0, "${LIBEV_SS_API_DIR}")
from key_store import KeyManager
km = KeyManager.from_config("/etc/libev/cli.json")
found = km.find_by_name("default")
print(found[0] if found else "")
PYEOF
)" || port=""

    if [[ -z "${port}" ]]; then
        echo "VPN port dogrulama atlandi (default anahtar yok)" >> "${FULL_LOG}"
        return 0
    fi

    if command_exists ss; then
        ss -ltn 2>/dev/null | grep -qE ":${port}( |$)" && listening=1
        ss -lun 2>/dev/null | grep -qE ":${port}( |$)" && listening=1
    elif command_exists netstat; then
        netstat -ltn 2>/dev/null | grep -q ":${port} " && listening=1
        netstat -lun 2>/dev/null | grep -q ":${port} " && listening=1
    fi

    if (( listening == 0 )); then
        log_error "VPN port ${port} sunucuda dinlenmiyor! journalctl -u shadowsocks-manager -n 30"
        journalctl -u shadowsocks-manager -n 20 --no-pager >> "${FULL_LOG}" 2>&1 || true
        return 1
    fi

    echo "VPN port ${port} dinleniyor (ss-manager OK)" >> "${FULL_LOG}"
    return 0
}

function write_access_config() {
    readonly ACCESS_CONFIG="${LIBEV_INSTALL_DIR}/access.txt"
    mkdir -p "${LIBEV_INSTALL_DIR}"
    chmod 700 "${LIBEV_INSTALL_DIR}"

    cat > "${ACCESS_CONFIG}" <<EOF
apiUrl:${PUBLIC_API_URL}
certSha256:${CERT_SHA256}
internalApiUrl:http://127.0.0.1:${API_PORT}/${LIBEV_API_SECRET}
serverIp:${PUBLIC_HOSTNAME}
managerAddress:${MANAGER_SOCKET}
type:libev
portRange:${LIBEV_PORT_START}-${LIBEV_PORT_END}
EOF
    chmod 600 "${ACCESS_CONFIG}"
}

function write_telecom_watch_script() {
    cat > "${TELECOM_WATCH_SCRIPT}" <<'PYEOF'
#!/usr/bin/env python3
"""telecom.tm erisim gozcusu.

Sonucu bota POST etmez. Durumu yerel JSON dosyasina yazar; ss-api
GET /server (ve GET /server-status) bu dosyayi okur.

Siniflandirma:
  * Baglanti hic kurulamazsa -> status="blocked"
  * HTTP yaniti alinirsa (200/403/404/503 ...) -> status="online"
"""
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DEFAULT_CONFIG = "/etc/libev/telecom.json"
DEFAULT_STATUS = "/etc/libev/telecom_status.json"


def load_config(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def check_target(target):
    """(status, http_code, detail) dondurur."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    url = target if target.startswith(("https://", "http://")) else "https://" + target
    req = urllib.request.Request(
        url,
        method="GET",
        headers={"User-Agent": "telecom-watch/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            return "online", getattr(resp, "status", 200), "ok"
    except urllib.error.HTTPError as exc:
        return "online", exc.code, "http-error"
    except urllib.error.URLError as exc:
        return "blocked", 0, str(getattr(exc, "reason", exc))
    except (socket.timeout, TimeoutError):
        return "blocked", 0, "timeout"
    except Exception as exc:  # noqa: BLE001
        return "blocked", 0, str(exc)


def check_targets_parallel(targets):
    """Uc farkli hedefi uc paralel baglanti ile dene ve raporla."""
    with ThreadPoolExecutor(max_workers=3) as executor:
        checks = list(executor.map(check_target, targets))

    attempts = [
        {
            "target": target,
            "ok": status == "online",
            "http_code": http_code,
            "detail": detail,
        }
        for target, (status, http_code, detail) in zip(targets, checks)
    ]
    successful = sum(1 for attempt in attempts if attempt["ok"])
    failed = len(attempts) - successful
    # Tek bir baglanti bile kurulursa sunucu erisilebilir kabul edilir.
    status = "online" if successful else "blocked"
    http_code = next((item["http_code"] for item in attempts if item["ok"]), 0)
    detail = "; ".join(item["detail"] for item in attempts if item["detail"])
    return status, http_code, detail, attempts, successful, failed


def write_status(path, payload):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass


def main():
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    try:
        cfg = load_config(cfg_path)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("config okunamadi (%s): %s\n" % (cfg_path, exc))
        return 1

    targets = cfg.get("targets") or [
        "https://telecom.tm", "https://astu.tm", "https://e.gov.tm"
    ]
    if not isinstance(targets, list):
        targets = [str(targets)]
    targets = [str(target).strip() for target in targets if str(target).strip()][:3]
    if len(targets) != 3:
        targets = ["https://telecom.tm", "https://astu.tm", "https://e.gov.tm"]
    status, http_code, detail, attempts, successful, failed = check_targets_parallel(targets)

    payload = {
        "server_ip": cfg.get("server_ip", ""),
        "server_name": cfg.get("server_name", ""),
        "status": status,
        "http_code": http_code,
        "target": ", ".join(targets),
        "detail": detail,
        "checked_at": int(time.time()),
        "attempt_results": attempts,
        "successful_attempts": successful,
        "failed_attempts": failed,
    }

    status_path = (cfg.get("status_file") or "").strip() or DEFAULT_STATUS
    write_status(status_path, payload)
    sys.stdout.write(
        "telecom=%s ok=%s false=%s http=%s detail=%s -> api=%s\n"
        % (status, successful, failed, http_code, detail, status_path)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
    chmod 755 "${TELECOM_WATCH_SCRIPT}"
}

function setup_telecom_watch() {
    write_telecom_watch_script

    cat > "${TELECOM_CONFIG}" <<EOF
{
  "server_ip": "${PUBLIC_HOSTNAME}",
  "server_name": "${FLAGS_SERVER_NAME}",
    "targets": ["https://telecom.tm", "https://astu.tm", "https://e.gov.tm"],
  "status_file": "${TELECOM_STATUS_FILE}"
}
EOF
    chmod 600 "${TELECOM_CONFIG}"

    cat > /etc/systemd/system/telecom-watch.service <<EOF
[Unit]
Description=telecom.tm erisim gozcusu (libev)
After=network-online.target ss-api.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${TELECOM_WATCH_SCRIPT} ${TELECOM_CONFIG}
EOF

    cat > /etc/systemd/system/telecom-watch.timer <<EOF
[Unit]
Description=telecom.tm gozcusunu her ${TELECOM_INTERVAL} saniyede calistir

[Timer]
OnBootSec=30
OnUnitActiveSec=${TELECOM_INTERVAL}
AccuracySec=5s
Unit=telecom-watch.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable telecom-watch.timer >/dev/null 2>&1
    systemctl restart telecom-watch.timer
    echo "telecom gozcusu ${TELECOM_INTERVAL}s araliginda telecom.tm, astu.tm ve e.gov.tm adreslerini paralel test eder; bot GET /server ile okur." >> "${FULL_LOG}"
}

function output_install_result() {
    local outline_json test_port test_url
    outline_json="$(printf '{"apiUrl":"%s","certSha256":"%s"}' "${PUBLIC_API_URL}" "${CERT_SHA256}")"

    read -r test_port test_url < <(python3 <<PYEOF 2>>"${FULL_LOG}" || true
import sys
sys.path.insert(0, "${LIBEV_SS_API_DIR}")
from key_store import KeyManager
km = KeyManager.from_config("/etc/libev/cli.json")
found = km.find_by_name("default")
if not found:
    print("", "")
else:
    port, entry = found
    payload = km.key_payload(port, entry)
    print(port, payload.get("accessUrl", ""))
PYEOF
) || true

    cat <<EOF

Congratulations! This Libev server is ready to use.

Outline uyumlu API JSON (bot config icin):

${outline_json}

Onemli:
- API portu: ${API_TLS_PORT}/tcp
- VPN port araligi: ${LIBEV_PORT_START}-${LIBEV_PORT_END}/tcp+udp (tek cihaz, IP kilidi VAR)
- Coklu cihaz portu: ${LIBEV_MULTI_PORT}/tcp+udp (IP kilidi YOK; bulut panelinde 443'u de acin)
- nofile limiti: 65535 (ss-manager -n 65535)
- telecom/astu/e.gov.tm gozcusu: her ${TELECOM_INTERVAL}s -> ${TELECOM_STATUS_FILE}
- Bot bu durumu API'den okur: GET /server  (alan: telecomStatus)
EOF

    if [[ -n "${test_port}" ]]; then
        cat <<EOF
- Test VPN portu: ${test_port} (sunucuda dinleniyor)
- Ornek ss://: ${test_url}
EOF
    fi

    cat <<EOF
- Kurulum logu: ${FULL_LOG}

ss:// calismiyorsa (ufw kapali olsa bile):
- Port senkronu: libev sync  (manager restart sonrasi ports.json -> ss-manager)
- ss:// icindeki IP sunucunun gercek public IP'si mi? (curl -4 ifconfig.me ile karsilastirin)
- Port dinleniyor mu? ss -ltn | grep PORT
- IP kilidi var mi? libev status port PORT  /  libev unlock-ip key ISIM
- journalctl -u shadowsocks-manager -n 30
EOF
}

function finish() {
    local -ir code=$?
    if (( code != 0 )); then
        if [[ -s "${LAST_ERROR}" ]]; then
            log_error "Son hata:"
            tail -20 "${LAST_ERROR}" >&2
        fi
        log_error "Kurulum basarisiz. Tam log: ${FULL_LOG}"
    else
        echo "Kurulum tamamlandi. Log: ${FULL_LOG}" >> "${FULL_LOG}"
    fi
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                FLAGS_HOSTNAME="$2"
                shift 2
                ;;
            --api-port)
                FLAGS_API_PORT="$2"
                shift 2
                ;;
            --api-tls-port)
                FLAGS_API_TLS_PORT="$2"
                shift 2
                ;;
            --manager-port)
                FLAGS_MANAGER_PORT="$2"
                shift 2
                ;;
            --bot-url)
                FLAGS_BOT_URL="$2"
                shift 2
                ;;
            --server-name)
                FLAGS_SERVER_NAME="$2"
                shift 2
                ;;
            --local)
                FLAGS_LOCAL=1
                shift 1
                ;;
            --patch-telecom-api)
                FLAGS_PATCH_TELECOM=1
                shift 1
                ;;
            -h|--help)
                display_usage
                exit 0
                ;;
            *)
                log_error "Bilinmeyen arguman: $1"
                display_usage
                exit 1
                ;;
        esac
    done
}

function apply_telecom_api_only() {
    require_root
    mkdir -p /etc/libev "${LIBEV_SS_API_DIR}"
    write_telecom_watch_script
    patch_ss_api_telecom_status

    python3 - <<PYEOF
import json
import os
path = "${TELECOM_CONFIG}"
status_file = "${TELECOM_STATUS_FILE}"
cfg = {}
if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh) or {}
    except Exception:
        cfg = {}
cfg["status_file"] = status_file
cfg.pop("bot_url", None)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.chmod(path, 0o600)
print("telecom.json guncellendi: status_file=%s" % status_file)
PYEOF

    local unit="/etc/systemd/system/ss-api.service"
    if [[ -f "${unit}" ]] && ! grep -q 'TELECOM_STATUS_FILE=' "${unit}"; then
        if grep -q '^Environment=LIBEV_MULTI_PORTS=' "${unit}"; then
            sed -i "/Environment=LIBEV_MULTI_PORTS=/a Environment=TELECOM_STATUS_FILE=${TELECOM_STATUS_FILE}" "${unit}"
        else
            sed -i "/^\[Service\]/a Environment=TELECOM_STATUS_FILE=${TELECOM_STATUS_FILE}" "${unit}"
        fi
    fi

    systemctl daemon-reload
    systemctl restart ss-api.service || true
    python3 "${TELECOM_WATCH_SCRIPT}" "${TELECOM_CONFIG}" || true
    systemctl restart telecom-watch.timer || true
    echo "telecom durumu artik API GET /server (telecomStatus) uzerinden okunur."
}

function main() {
    trap finish EXIT
    echo "Canli kurulum logu: ${FULL_LOG}  (ayri bir oturumda: tail -f ${FULL_LOG})"
    parse_args "$@"

    if (( FLAGS_PATCH_TELECOM == 1 )); then
        apply_telecom_api_only
        exit 0
    fi

    require_root

    run_step "APT mirror kontrol ediliyor" setup_apt_mirror

    MACHINE_TYPE="$(uname -m)"
    if [[ "${MACHINE_TYPE}" != "x86_64" && "${MACHINE_TYPE}" != "aarch64" ]]; then
        log_error "Desteklenmeyen mimari: ${MACHINE_TYPE}"
        exit 1
    fi
    readonly MACHINE_TYPE

    if ! command_exists curl; then
        apt_update
        apt_install curl ca-certificates
    fi
    API_PORT="${FLAGS_API_PORT}"
    if (( API_PORT == 0 )); then
        API_PORT=8087
    fi
    readonly API_PORT

    API_TLS_PORT="${FLAGS_API_TLS_PORT}"
    if (( API_TLS_PORT == 0 )); then
        API_TLS_PORT="${LIBEV_API_TLS_PORT:-55555}"
    fi
    readonly API_TLS_PORT

    if (( FLAGS_MANAGER_PORT != 0 )); then
        echo "> Not: --manager-port kullanilmiyor; unix socket: ${MANAGER_SOCKET}"
    fi

    PUBLIC_HOSTNAME="${FLAGS_HOSTNAME}"
    if [[ -z "${PUBLIC_HOSTNAME}" ]]; then
        run_step "Public IP tespit ediliyor" detect_public_ip
        refresh_server_ip
    fi
    readonly PUBLIC_HOSTNAME

    echo "Tespit edilen OS: $(detect_host_os_tag) (glibc $(host_glibc_version))" >> "${FULL_LOG}"

    run_step "Bagimliliklar kuruluyor" install_dependencies
    if (( FLAGS_LOCAL == 1 )); then
        run_step "Yerel dosyalar kopyalaniyor" fetch_server_sources
    else
        run_step "Dosyalar indiriliyor" fetch_server_sources
    fi
    run_step "Binary kuruluyor" install_shadowsocks_binaries
    run_step "Python bagimliliklari kuruluyor" install_python_deps
    run_step "API secret uretiliyor" generate_api_secret
    run_step "Yapilandirma yaziliyor" write_configs
    run_step "Sistem limitleri ayarlaniyor" configure_system_limits
    if [[ ! -s "${LIBEV_WORKDIR}/ports.json" ]]; then
        rm -f "${LIBEV_WORKDIR}"/.shadowsocks_*.iplock "${LIBEV_WORKDIR}"/.shadowsocks_*.ipstatus 2>/dev/null || true
    else
        echo "Mevcut ports.json korunuyor; IP kilidi dosyalari silinmedi." >> "${FULL_LOG}"
    fi
    run_step "HTTPS API (nginx) kuruluyor" setup_api_tls
    run_step "Servisler baslatiliyor" start_services
    run_step "ss-manager bekleniyor" wait_for_manager
    run_step "API bekleniyor" wait_for_api
    run_step "Genel HTTPS API dogrulaniyor" verify_public_api
    run_step "ss-manager portlari senkronize ediliyor" sync_manager_ports
    run_step "Ilk anahtar olusturuluyor" create_first_access_key
    run_step "VPN portu dogrulaniyor" verify_vpn_listening
    run_step "Access config yaziliyor" write_access_config
    run_step "telecom.tm gozcusu kuruluyor" setup_telecom_watch

    output_install_result
}

main "$@"
