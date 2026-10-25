# shellcheck shell=bash
# Fallback glibc cross toolchain for hosts without a distro cross gcc
# (macOS: nix can't build glibc on a case-insensitive filesystem).
#
#   cross_clang_setup <aarch64|x86_64>
#
# Writes <triple>-{gcc,g++,ar,ranlib,strip,nm,objdump,readelf,ld}
# wrappers (triple = aarch64-linux-gnu / x86_64-linux-gnu) around clang,
# lld and the llvm binutils, targeting the Arch sysroot from
# build-host-sysroot.sh, and prepends them to PATH. The sysroot gets
# `gcc` added for libstdc++ headers, crt files and libgcc, plus the
# Vulkan/X11 headers libhybris needs. Sets CROSS_CLANG_SYSROOT.
#
# Uses $TAWC_CROSS_CLANG (an *unwrapped* clang; the nix shell sets it)
# or `clang` from PATH.

cross_clang_setup() {
    local abi="$1"
    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local triple="$abi-linux-gnu"
    local clang="${TAWC_CROSS_CLANG:-$(command -v clang || true)}"
    local tool
    for tool in "$clang" ld.lld llvm-ar llvm-ranlib llvm-strip llvm-nm llvm-objdump llvm-readelf; do
        command -v "$tool" >/dev/null || {
            echo "ERROR: no $triple-gcc and no clang fallback ('$tool' missing)." >&2
            echo "       Install the $abi glibc cross-toolchain (notes/building.md)" >&2
            echo "       or use the nix shell (shell.nix)." >&2
            return 1
        }
    done

    CROSS_CLANG_SYSROOT="$repo_dir/build/sysroots/${TAWC_SYSROOT_DISTRO:-arch}-$abi"
    if [ ! -d "$CROSS_CLANG_SYSROOT/usr/include/c++" ] \
            || [ ! -f "$CROSS_CLANG_SYSROOT/usr/include/vulkan/vulkan.h" ] \
            || [ ! -f "$CROSS_CLANG_SYSROOT/usr/include/X11/Xlib-xcb.h" ]; then
        TAWC_SYSROOT_EXTRA_PACKAGES="gcc vulkan-headers libx11 libxcb xorgproto libxau libxdmcp" \
            "$repo_dir/scripts/build-host-sysroot.sh" "--abi=$abi" --profile=prod || return 1
    fi

    local bin="$repo_dir/build/cross-clang-$abi"
    mkdir -p "$bin"
    # libhybris's hooks.c calls glibc's __v{s,sn}printf_chk, which gcc
    # knows as builtins; glibc only declares them under _FORTIFY_SOURCE.
    cat >"$bin/chk-decls.h" <<'EOF'
#ifndef __ASSEMBLER__
#ifdef __cplusplus
extern "C" {
#endif
int __vsprintf_chk(char *, int, __SIZE_TYPE__, const char *, __builtin_va_list);
int __vsnprintf_chk(char *, __SIZE_TYPE__, int, __SIZE_TYPE__, const char *, __builtin_va_list);
#ifdef __cplusplus
}
#endif
#endif
EOF
    # Trailing -Wno-error=s (after the caller's -Werror=s) for things gcc
    # doesn't flag: libhybris's q/linker.cpp passes std::vector to TRACE()
    # varargs (clang traps if that debug-only TRACE ever runs), and Mesa's
    # -Werror=incompatible-pointer-types covers discarded qualifiers in
    # clang but not gcc.
    # -fuse-ld only on link steps: meson's checks add
    # -Werror=unused-command-line-argument, which it trips on -c.
    local fe
    for fe in gcc g++; do
        cat >"$bin/$triple-$fe" <<EOF
#!/bin/sh
ld=-fuse-ld=lld
for a in "\$@"; do case "\$a" in -c|-E|-S|-M|-MM) ld= ;; esac; done
exec "$clang" --driver-mode=$fe --target=$abi-unknown-linux-gnu --sysroot="$CROSS_CLANG_SYSROOT" \$ld -include "$bin/chk-decls.h" "\$@" \\
    -Wno-error=non-pod-varargs -Wno-error=incompatible-pointer-types-discards-qualifiers
EOF
        chmod +x "$bin/$triple-$fe"
    done
    for tool in ar ranlib strip nm objdump readelf; do
        ln -sf "$(command -v "llvm-$tool")" "$bin/$triple-$tool"
    done
    ln -sf "$(command -v ld.lld)" "$bin/$triple-ld"
    export PATH="$bin:$PATH"
}
