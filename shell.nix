# Nix shell for building TAWC (notes/building.md "Nix shell").
#
#   nix-shell            # then: scripts/build-app.sh
#
# Provides JDK 21, an Android SDK (platform 36, build-tools, the NDK
# pinned in app/build.gradle.kts), rustup (honours rust-toolchain.toml),
# cargo-ndk and the GNU userland the build scripts assume. Works on
# Linux and macOS hosts.
#
# nixpkgs is pinned below. To bump: set rev to a newer nixpkgs-unstable
# commit, set sha256 to "", run nix-shell and copy the hash it reports.
{ pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/901c54c08bdc20e00c2b3c73716b97497b1b3c74.tar.gz";
    sha256 = "sha256-KtL+p7f7jY34cO5Mt0/hUZNE3spnINk7hwpYxM2XLC4=";
  }) {
    config = { allowUnfree = true; android_sdk.accept_license = true; };
  }
}:

let
  ndkVersion = "27.2.12479018";
  android = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "35.0.0" "36.0.0" ];
    includeNDK = true;
    ndkVersions = [ ndkVersion ];
    includeEmulator = false;
    includeSystemImages = false;
    includeSources = false;
  };
  sdk = "${android.androidsdk}/libexec/android-sdk";
  # macOS has /usr/bin/gcc as an Xcode-install stub; native autotools
  # stages (font-util, makekeys) default to gcc, so alias it to clang.
  darwinGccAlias = pkgs.lib.optional pkgs.stdenv.hostPlatform.isDarwin
    (pkgs.runCommandLocal "gcc-clang-alias" { } ''
      mkdir -p $out/bin
      ln -s ${pkgs.clang}/bin/cc $out/bin/gcc
      ln -s ${pkgs.clang}/bin/c++ $out/bin/g++
    '');
  # libhybris needs an aarch64 glibc cross compiler. Linux hosts get
  # nixpkgs' cross gcc (binary-cached). macOS can't build glibc
  # (case-insensitive fs), so build-libhybris.sh falls back to
  # TAWC_CROSS_CLANG + lld + the Arch Linux ARM sysroot.
  linuxCrossCC = pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux
    pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc;
in
# NoCC, plus the unsets in shellHook: toolchain exports would leak
# into the NDK and cross builds. The host clang is for cargo build
# scripts and native helpers (wayland-scanner, makekeys, ...).
pkgs.mkShellNoCC {
  packages = with pkgs; [
    jdk21 rustup cargo-ndk
    bashInteractive coreutils findutils gnused gnugrep gawk gnutar
    gzip xz zstd unzip zip diffutils patch which file curl git
    gnumake meson ninja pkg-config bison flex
    autoconf automake libtool perl rust-bindgen
    (python3.withPackages (ps: with ps; [ mako pyyaml packaging libxml2 ]))
    clang lld llvm patchelf flock libarchive wayland-scanner
  ] ++ linuxCrossCC ++ darwinGccAlias;
  # Headers libhybris's synthetic .pc files point at (found via
  # pkg-config); only headers are used, never the host libs.
  # expat: Xwayland builds a native wayland-scanner against it.
  buildInputs = [ pkgs.expat ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (with pkgs; [
    wayland wayland-protocols vulkan-headers libx11 libxcb
  ]);
  ANDROID_HOME = sdk;
  ANDROID_SDK_ROOT = sdk;
  ANDROID_NDK_HOME = "${sdk}/ndk/${ndkVersion}";
  JAVA_HOME = pkgs.jdk21.home;
  TAWC_CROSS_CLANG = "${pkgs.llvmPackages.clang-unwrapped}/bin/clang";
  shellHook = ''
    # The host clang's setup hook exports these. The build scripts
    # assign CC=<NDK clang> etc. without exporting, which would
    # otherwise turn into an export and leak into native (build
    # machine) sub-builds such as Xwayland's wayland-scanner.
    unset CC CXX AR AS LD NM RANLIB STRIP OBJCOPY OBJDUMP SIZE STRINGS
    # Autotools build-machine tools (libX11's makekeys): without
    # this, configure picks `gcc`, the Xcode stub on macOS.
    export CC_FOR_BUILD=cc
    # Gradle's daemon-JVM pin needs to find this JDK 21.
    export GRADLE_OPTS="-Dorg.gradle.java.installations.paths=$JAVA_HOME ''${GRADLE_OPTS:-}"
  '';
}
