#!/bin/bash
# ss-server / ss-manager — Ubuntu 22.04 ve 24.04 icin ayri prebuilt binary uretir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/shadowsocks-libev"
OUT_BASE="${SCRIPT_DIR}/bin/x86_64"

# ubuntu_version|out_dir|glibc_alias
BUILD_TARGETS=(
    "22.04|ubuntu22.04|glibc2.35"
    "24.04|ubuntu24.04|glibc2.38"
)

if [[ ! -f "${SRC_DIR}/CMakeLists.txt" ]]; then
    echo "Kaynak bulunamadi: ${SRC_DIR}" >&2
    exit 1
fi

copy_binaries_to() {
    local from_dir="$1"
    local out_tag="$2"
    local glibc_alias="${3:-}"
    local out_dir="${OUT_BASE}/${out_tag}"

    mkdir -p "${out_dir}"
    cp -f "${from_dir}/ss-server" "${out_dir}/"
    cp -f "${from_dir}/ss-manager" "${out_dir}/"
    chmod 755 "${out_dir}/ss-server" "${out_dir}/ss-manager"

    if [[ -n "${glibc_alias}" ]]; then
        local alias_dir="${OUT_BASE}/${glibc_alias}"
        mkdir -p "${alias_dir}"
        cp -f "${from_dir}/ss-server" "${alias_dir}/"
        cp -f "${from_dir}/ss-manager" "${alias_dir}/"
        chmod 755 "${alias_dir}/ss-server" "${alias_dir}/ss-manager"
    fi
}

build_with_docker() {
    local ubuntu_ver="$1"
    local out_tag="$2"
    local glibc_alias="${3:-}"
    local docker_image="ubuntu:${ubuntu_ver}"

    echo "========================================"
    echo "Docker derleme: ${docker_image} -> ${out_tag}"
    echo "========================================"

    docker run --rm \
        -v "${SCRIPT_DIR}:/work" \
        -w /work/shadowsocks-libev \
        "${docker_image}" \
        bash -lc '
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq build-essential cmake pkg-config \
                libev-dev libsodium-dev libpcre2-dev libc-ares-dev libmbedtls-dev
            rm -rf build
            mkdir -p build
            cd build
            cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_STATIC=OFF
            make -j"$(nproc 2>/dev/null || echo 4)" ss-server-shared ss-manager-shared
        '

    copy_binaries_to "${SRC_DIR}/build/shared/bin" "${out_tag}" "${glibc_alias}"
    echo "OK: ${OUT_BASE}/${out_tag}/"
}

build_local_single() {
    local out_tag="$1"
    local glibc_alias="${2:-}"
    local build_dir="${SRC_DIR}/build-${out_tag}"

    echo "Yerel derleme -> ${out_tag}"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    cmake -S "${SRC_DIR}" -B "${build_dir}" -DCMAKE_BUILD_TYPE=Release -DWITH_STATIC=OFF
    cmake --build "${build_dir}" --target ss-server-shared ss-manager-shared \
        -j"$(nproc 2>/dev/null || echo 4)"
    copy_binaries_to "${build_dir}/shared/bin" "${out_tag}" "${glibc_alias}"
}

if [[ "${LIBEV_BUILD_LOCAL:-0}" == "1" ]]; then
    build_local_single "${LIBEV_BUILD_TAG:-ubuntu22.04}" "${LIBEV_BUILD_GLIBC:-glibc2.35}"
elif command -v docker >/dev/null 2>&1; then
    for entry in "${BUILD_TARGETS[@]}"; do
        IFS='|' read -r ubuntu_ver out_tag glibc_alias <<< "${entry}"
        build_with_docker "${ubuntu_ver}" "${out_tag}" "${glibc_alias}"
    done
else
    echo "Docker yok; yalnizca ubuntu22.04 yerel derleme." >&2
    build_local_single "ubuntu22.04" "glibc2.35"
fi

echo ""
echo "BUILD OK"
echo "  ${OUT_BASE}/ubuntu22.04/  (Ubuntu 22.04 / glibc 2.35)"
echo "  ${OUT_BASE}/ubuntu24.04/  (Ubuntu 24.04 / glibc 2.38)"
ls -la "${OUT_BASE}/ubuntu22.04/" 2>/dev/null || true
ls -la "${OUT_BASE}/ubuntu24.04/" 2>/dev/null || true
