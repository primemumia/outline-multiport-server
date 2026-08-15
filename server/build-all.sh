#!/bin/bash
set -euo pipefail

WIN_OUT="/mnt/c/Users/prime/Desktop/test out/server/bin/x86_64"
WORK="$HOME/libev-build"
SRC="$WORK/shadowsocks-libev"

rm -rf "$WORK"
mkdir -p "$WORK"
rsync -a "/mnt/c/Users/prime/Desktop/test out/server/shadowsocks-libev/" "$SRC/"

echo "Building (native WSL -> ubuntu24.04)..."
rm -rf "${SRC}/build"
cmake -S "$SRC" -B "${SRC}/build" -DCMAKE_BUILD_TYPE=Release -DWITH_STATIC=OFF
cmake --build "${SRC}/build" --target ss-server-shared ss-manager-shared -j"$(nproc 2>/dev/null || echo 4)"

for tag in ubuntu24.04 glibc2.38; do
    out_dir="${WIN_OUT}/${tag}"
    mkdir -p "$out_dir"
    cp -f "${SRC}/build/shared/bin/ss-server" "${SRC}/build/shared/bin/ss-manager" "$out_dir/"
    chmod 755 "$out_dir/ss-server" "$out_dir/ss-manager"
done

echo "OK: ${WIN_OUT}/ubuntu24.04/"
