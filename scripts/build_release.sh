#!/usr/bin/env bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN="${OO_PS4_TOOLCHAIN:-${PROJECT}/../OpenOrbis-PS4-Toolchain}"

if [[ ! -f "${TOOLCHAIN}/link.x" ]]; then
    LINKER_SCRIPT="$(find "${TOOLCHAIN}" -maxdepth 5 -type f -name link.x -print -quit)"
    if [[ -z "${LINKER_SCRIPT}" ]]; then
        echo "OpenOrbis link.x was not found under ${TOOLCHAIN}" >&2
        exit 1
    fi
    TOOLCHAIN="$(dirname "${LINKER_SCRIPT}")"
fi
BIN_DIR="${TOOLCHAIN}/bin/linux"

mkdir -p "${PROJECT}/bin" "${PROJECT}/daemon/obj" "${PROJECT}/app/obj" "${PROJECT}/app/bin" "${PROJECT}/app/assets/payload"

python3 "${PROJECT}/scripts/generate_version.py"

DAEMON_SOURCES=(
    daemon_syscalls main vpad usb_driver config log controller_detect translator generic_hid bt_driver
)
DAEMON_OBJECTS=()
for name in "${DAEMON_SOURCES[@]}"; do
    clang --target=x86_64-pc-freebsd12-elf -fPIC -funwind-tables \
        -fno-delete-null-pointer-checks -c -Wall \
        -isysroot "${TOOLCHAIN}" \
        -isystem "${TOOLCHAIN}/include" \
        -isystem "${TOOLCHAIN}/include/orbis/_types" \
        -I"${PROJECT}/daemon/include" -I"${PROJECT}/include" \
        -D__PS4__ -D__ORBIS__ \
        -o "${PROJECT}/daemon/obj/${name}.o" "${PROJECT}/daemon/src/${name}.c"
    DAEMON_OBJECTS+=("${PROJECT}/daemon/obj/${name}.o")
done

ld.lld -m elf_x86_64 -pie --script "${TOOLCHAIN}/link.x" --eh-frame-hdr \
    -L"${TOOLCHAIN}/lib" -o "${PROJECT}/bin/onefamily.elf" \
    "${DAEMON_OBJECTS[@]}" -lc -lkernel
cp "${PROJECT}/bin/onefamily.elf" "${PROJECT}/bin/onefamily.bin"
cp "${PROJECT}/bin/onefamily.bin" "${PROJECT}/app/assets/payload/onefamily.bin"

python3 "${PROJECT}/app/make_sfo_app.py"

APP_SOURCES=(
    main config_manager installer hid_profile pkg_updater ps_background ui
)
APP_OBJECTS=()
for name in "${APP_SOURCES[@]}"; do
    clang++ --target=x86_64-pc-freebsd12-elf -fPIC -funwind-tables \
        -fno-exceptions -fno-rtti -O2 -c -Wall -DGRAPHICS_USES_FONT \
        -isysroot "${TOOLCHAIN}" \
        -isystem "${TOOLCHAIN}/include" \
        -isystem "${TOOLCHAIN}/include/c++/v1" \
        -I"${PROJECT}/app/src" -I"${PROJECT}/app/src/common" -I"${PROJECT}/include" \
        -o "${PROJECT}/app/obj/${name}.o" "${PROJECT}/app/src/${name}.cpp"
    APP_OBJECTS+=("${PROJECT}/app/obj/${name}.o")
done

for name in graphics controller png; do
    clang++ --target=x86_64-pc-freebsd12-elf -fPIC -funwind-tables \
        -fno-exceptions -fno-rtti -O2 -c -Wall -DGRAPHICS_USES_FONT \
        -isysroot "${TOOLCHAIN}" \
        -isystem "${TOOLCHAIN}/include" \
        -isystem "${TOOLCHAIN}/include/c++/v1" \
        -I"${PROJECT}/app/src" -I"${PROJECT}/app/src/common" -I"${PROJECT}/include" \
        -o "${PROJECT}/app/obj/${name}.o" "${PROJECT}/app/src/common/${name}.cpp"
    APP_OBJECTS+=("${PROJECT}/app/obj/${name}.o")
done

ld.lld -m elf_x86_64 -pie --script "${TOOLCHAIN}/link.x" --eh-frame-hdr \
    -L"${TOOLCHAIN}/lib" "${TOOLCHAIN}/lib/crt1.o" \
    "${APP_OBJECTS[@]}" -o "${PROJECT}/app/bin/app.elf" \
    -lc -lkernel -lc++ -lSceVideoOut -lSceSysmodule -lSceFreeType \
    -lScePad -lSceUserService -lSceSystemService -lSceNet -lSceNetCtl -lSceSsl -lSceHttp

CREATE_FSELF="${BIN_DIR}/create-fself"
if [[ ! -x "${CREATE_FSELF}" ]]; then
    echo "OpenOrbis create-fself was not found at ${CREATE_FSELF}" >&2
    exit 1
fi
"${CREATE_FSELF}" -in="${PROJECT}/app/bin/app.elf" \
    -out="${PROJECT}/app/bin/app.oelf" --eboot "eboot.bin" \
    --paid 0x3800000000000011 --library-path "${TOOLCHAIN}/lib"

PKGTOOL="${BIN_DIR}/PkgTool.Core"
if [[ -f "${BIN_DIR}/PkgTool.Core.dll" ]]; then
    run_pkgtool() { dotnet --roll-forward LatestMajor "${BIN_DIR}/PkgTool.Core.dll" "$@"; }
elif [[ -x "${PKGTOOL}" ]]; then
    run_pkgtool() { "${PKGTOOL}" "$@"; }
else
    echo "PkgTool.Core was not found in ${BIN_DIR}" >&2
    exit 1
fi

pushd "${PROJECT}/app" >/dev/null
run_pkgtool pkg_build pkg.gp4 .
run_pkgtool pkg_validate UP9000-XBOX00001_00-XBOXCONFIGURATOR.pkg
cp UP9000-XBOX00001_00-XBOXCONFIGURATOR.pkg "${PROJECT}/bin/onefamily_companion.pkg"
popd >/dev/null

test -s "${PROJECT}/bin/onefamily_companion.pkg"
shasum -a 256 "${PROJECT}/bin/onefamily_companion.pkg" | tee "${PROJECT}/bin/onefamily_companion.pkg.sha256"
