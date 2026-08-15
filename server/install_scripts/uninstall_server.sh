#!/bin/bash
#
# Libev server tam kaldirma — libev server delete
#
set -euo pipefail

readonly LIBEV_INSTALL_DIR="${LIBEV_INSTALL_DIR:-/opt/libev-server}"
readonly LIBEV_WORKDIR="${LIBEV_WORKDIR:-/var/lib/shadowsocks-manager}"
readonly LIBEV_SS_API_DIR="${LIBEV_SS_API_DIR:-/opt/ss-api}"
readonly LIBEV_SRC_DIR="${LIBEV_SRC_DIR:-/opt/shadowsocks-libev}"
readonly MANAGER_SOCKET="${MANAGER_SOCKET:-${LIBEV_WORKDIR}/manager.sock}"
readonly SSL_DIR="/etc/libev/ssl"
readonly RUNTIME_DIR="/run/shadowsocks-manager"

function require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Root gerekli: sudo libev server delete --yes" >&2
        exit 1
    fi
}

function stop_services() {
    systemctl stop ss-api shadowsocks-manager 2>/dev/null || true
    systemctl disable ss-api shadowsocks-manager 2>/dev/null || true
    pkill -f '/usr/local/bin/ss-server' 2>/dev/null || true
    sleep 1
}

function remove_systemd_units() {
    rm -f /etc/systemd/system/shadowsocks-manager.service
    rm -f /etc/systemd/system/ss-api.service
    systemctl daemon-reload
}

function remove_nginx_site() {
    rm -f /etc/nginx/sites-enabled/libev-api
    rm -f /etc/nginx/sites-available/libev-api
    if command -v nginx >/dev/null 2>&1; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
}

function remove_files() {
    rm -f /usr/local/bin/ss-server /usr/local/bin/ss-manager /usr/local/bin/libev
    rm -rf "${LIBEV_INSTALL_DIR}" "${LIBEV_SS_API_DIR}" "${LIBEV_SRC_DIR}"
    rm -rf "${LIBEV_WORKDIR}" "${SSL_DIR}" /etc/libev
    rm -rf "${RUNTIME_DIR}"
    rm -f "${MANAGER_SOCKET}"
}

function main() {
    require_root

    if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
        echo "Tum libev kurulumu silinecek (servisler, anahtarlar, API, binary)." >&2
        echo "Onaylamak icin: libev server delete --yes" >&2
        exit 1
    fi

    echo "Libev server kaldiriliyor..."
    stop_services
    remove_systemd_units
    remove_nginx_site
    remove_files
    echo
    echo "Kaldirma tamamlandi."
    echo
    echo "Yeniden kurulum:"
    echo '  sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/primemumia/outline-libev-server/main/server/install_scripts/install_server.sh)"'
}

main "$@"
