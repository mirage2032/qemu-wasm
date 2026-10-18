#!/usr/bin/env bash
# Builds the qemu-system-x86_64 that lazyscript.com's simplos page boots:
# QEMU drawing to a canvas through SDL, rather than the -nographic builds the
# README describes.
#
#   ./build-simplos.sh [out-dir]        (default: ./out-simplos)
#
# Leaves out.js, qemu-system-x86_64.wasm (stripped) and
# qemu-system-x86_64.worker.js in out-dir. Needs Docker; the first run also
# builds the toolchain image from ./Dockerfile, which takes a while.
#
# What the page relies on, and so what must not change here:
#   --enable-sdl, -sUSE_SDL=2   the screen; upstream leaves SDL off.
#   -sOFFSCREENCANVAS_SUPPORT   SDL draws from QEMU's thread, not the page's.
#   EXPORTED_RUNTIME_METHODS=FS the page writes the firmware and disks itself.
#   emscripten-pty.js           load-bearing although out.js shows no trace of
#                               it: without it the guest stops after QEMU's
#                               first ROM message.
#   emsdk 3.1.50 (Dockerfile)   newer ones drop mainScriptUrlOrBlob, which lets
#                               the worker import out.js from another origin.
#   the heap                    starts at 512 MiB and may grow to 2 GiB. The
#                               page asks for the heap the guest's RAM needs
#                               (Module.INITIAL_MEMORY); without growth
#                               emscripten pins the maximum to the initial
#                               size and it could not. No more than 2 GiB:
#                               past that, pointers need CAN_ADDRESS_2GB.
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-out-simplos}"
container=build-qemu-wasm-simplos

docker build -t buildqemu - < Dockerfile
docker rm -f "$container" >/dev/null 2>&1 || true
docker run --rm -d --name "$container" -v "$PWD":/qemu/:ro buildqemu >/dev/null
trap 'docker rm -f "$container" >/dev/null' EXIT

flags="-O3 -g -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG \
-DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM \
-sALLOW_TABLE_GROWTH -sINITIAL_MEMORY=512MB -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB \
-sWASM_BIGINT -sMALLOC=mimalloc -sUSE_SDL=2 -sOFFSCREENCANVAS_SUPPORT \
--js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 \
-sASYNCIFY_IMPORTS=ffi_call_js"

# QEMU's configure finds SDL through sdl2-config; emscripten's answers -sUSE_SDL=2.
docker exec -e SDL2_CONFIG=/emsdk/upstream/emscripten/system/bin/sdl2-config "$container" \
    emconfigure /qemu/configure --static --target-list=x86_64-softmmu --cpu=wasm32 --cross-prefix= \
    --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs --enable-sdl \
    --extra-cflags="$flags" --extra-cxxflags="$flags" \
    --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
docker exec "$container" emmake make -j"$(nproc)" qemu-system-x86_64

# With -g the wasm is ~44 MB, almost all DWARF; stripped it is ~13.4 MB.
docker exec "$container" /emsdk/upstream/bin/wasm-opt qemu-system-x86_64.wasm \
    -o qemu-system-x86_64.wasm --strip-debug --strip-dwarf --strip-producers \
    --enable-bulk-memory --enable-threads --enable-mutable-globals --enable-sign-ext \
    --enable-nontrapping-float-to-int --enable-reference-types

mkdir -p "$out"
docker cp "$container":/build/qemu-system-x86_64 "$out/out.js"
for f in qemu-system-x86_64.wasm qemu-system-x86_64.worker.js; do
    docker cp "$container:/build/$f" "$out/"
done
echo "id: 8.2.0-$(cat "$out/qemu-system-x86_64.wasm" "$out/out.js" | sha256sum | cut -c1-12)"
