#!/bin/bash

shopt -s extglob

git_clone_path istoreos-25.12 https://github.com/istoreos/istoreos target/linux/amlogic package/boot/uboot-amlogic-prebuilt

rm -rf package/kernel/r81* target/linux/amlogic/base-files/etc/inittab

sed -i 's/DEFAULT_PACKAGES +=/DEFAULT_PACKAGES += luci-app-diskman automount/' target/linux/amlogic/Makefile

# BEGIN N1-HONK-ACTIONS
(
    set -euo pipefail
    echo "== N1 Honk: configure SquashFS and built-in kernel BTF =="

    append_config() {
        local line="$1"
        grep -qxF "$line" .config || printf '%s\n' "$line" >> .config
    }

    append_config 'CONFIG_TARGET_ROOTFS_EXT4FS=n'
    append_config 'CONFIG_TARGET_ROOTFS_SQUASHFS=y'
    append_config 'CONFIG_KERNEL_DEBUG_INFO=y'
    append_config 'CONFIG_KERNEL_DEBUG_INFO_BTF=y'
    append_config 'CONFIG_KERNEL_DEBUG_INFO_REDUCED=n'
    append_config 'CONFIG_PACKAGE_honk=y'
    append_config 'CONFIG_PACKAGE_luci-app-honk=y'
    append_config 'CONFIG_PACKAGE_luci-lib-daeuniverse=y'
    append_config 'CONFIG_PACKAGE_vmlinux-btf-builtin=y'
    append_config 'CONFIG_PACKAGE_v2ray-geoip=y'
    append_config 'CONFIG_PACKAGE_v2ray-geosite=y'

    # Keep this first Honk image intentionally small and avoid known-broken
    # optional packages from the previous OpenWrt.ai build logs. They can be
    # re-enabled one by one after the N1 boots reliably.
    append_config '# CONFIG_PACKAGE_luci-app-istorex is not set'
    append_config '# CONFIG_PACKAGE_luci-app-quickstart is not set'

    echo "== N1 Honk: install host build prerequisites =="
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        clang llvm libbpf-dev libelf-dev libclang-dev pkg-config cmake zstd binutils

    echo "== N1 Honk: add the official DAE Universe OpenWrt package feed =="
    rm -rf package/daeuniverse
    git clone --depth 1 https://github.com/daeuniverse/openwrt-packages.git package/daeuniverse
    grep -qxF 'src-link daeuniverse package/daeuniverse' feeds.conf.default || \
        printf '%s\n' 'src-link daeuniverse package/daeuniverse' >> feeds.conf.default
    ./scripts/feeds update daeuniverse
    ./scripts/feeds install -p daeuniverse honk luci-app-honk luci-lib-daeuniverse vmlinux-btf-builtin

    echo "== N1 Honk: fetch the pinned Honk source for its toolchain pins =="
    HONK_SRC="$(mktemp -d)/honk"
    git clone --depth 1 --branch v0.1.0-beta.6 https://github.com/daeuniverse/honk.git "$HONK_SRC"
    rm -rf package/daeuniverse/honk/src
    mkdir -p package/daeuniverse/honk
    cp -a "$HONK_SRC" package/daeuniverse/honk/src

    STABLE_TOOLCHAIN="$(grep -oP '^channel\s*=\s*"\K[^"]+' "$HONK_SRC/rust-toolchain.toml" | head -n1)"
    EBPF_TOOLCHAIN="$(grep -oP '^channel\s*=\s*"\K[^"]+' "$HONK_SRC/crates/honk-ebpf/rust-toolchain.toml" | head -n1)"
    if [ -z "$STABLE_TOOLCHAIN" ] || [ -z "$EBPF_TOOLCHAIN" ]; then
        echo "::error::Could not read the pinned Rust toolchains from Honk"
        exit 1
    fi

    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    export PATH="$CARGO_HOME/bin:$PATH"

    if ! command -v rustup >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    # rustup's installer places cargo in CARGO_HOME/bin
    export PATH="$CARGO_HOME/bin:$PATH"

    rustup toolchain install "$STABLE_TOOLCHAIN" --profile minimal \
        --component rustfmt --component clippy --target aarch64-unknown-linux-musl
    rustup toolchain install "$EBPF_TOOLCHAIN" --profile minimal \
        --component rust-src --component llvm-tools

    echo "== N1 Honk: install the exact upstream-pinned bpf-linker =="
    # This is the same pinned release URL and SHA256 verification used by
    # the DAE Universe official Honk package workflow.
    set -a
    # shellcheck disable=SC1091
    . "$HONK_SRC/.github/ci/pins.env"
    set +a
    if [ -z "${BPF_LINKER_VERSION:-}" ] || [ -z "${BPF_LINKER_SHA256:-}" ]; then
        echo "::error::Honk pins.env does not define BPF_LINKER_VERSION and BPF_LINKER_SHA256"
        exit 1
    fi
    RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}"
    mkdir -p "$CARGO_HOME/bin"
    curl -fsSL --retry 3 -o "$RUNNER_TEMP/bpf-linker.tar.zst" \
        "https://github.com/aya-rs/bpf-linker/releases/download/v${BPF_LINKER_VERSION}/bpf-linker-x86_64-unknown-linux-musl.tar.zst"
    echo "${BPF_LINKER_SHA256}  ${RUNNER_TEMP}/bpf-linker.tar.zst" | sha256sum -c -
    zstd -dc "$RUNNER_TEMP/bpf-linker.tar.zst" | tar -xf - -C "$CARGO_HOME/bin" bpf-linker
    "$CARGO_HOME/bin/bpf-linker" --version

    # Keep the toolchains available in later GitHub Actions steps, where
    # the existing Kwrt workflow invokes the full firmware compilation.
    printf '%s\n' "$CARGO_HOME/bin" >> "$GITHUB_PATH"
    {
        printf 'CARGO_HOME=%s\n' "$CARGO_HOME"
        printf 'RUSTUP_HOME=%s\n' "$RUSTUP_HOME"
    } >> "$GITHUB_ENV"

    echo "== N1 Honk: feed and pinned toolchains ready =="
)
# END N1-HONK-ACTIONS

# BEGIN N1-NIKKI-CLASHOO-CORE
# Nikki uses the Mihomo core; Clashoo ships a compatible core and provides
# the virtual "mihomo" package. Reuse that one copy to avoid competing
# /usr/bin/mihomo providers in the final rootfs.
NIKKI_MAKEFILE="package/feeds/kiddin9/nikki/Makefile"
if [ -f "$NIKKI_MAKEFILE" ]; then
    if grep -q '+mihomo' "$NIKKI_MAKEFILE"; then
        sed -i 's/+mihomo/+clashoo/g' "$NIKKI_MAKEFILE"
    fi
    grep -q '+clashoo' "$NIKKI_MAKEFILE" || {
        echo "::error::Nikki package dependency could not be redirected to Clashoo Mihomo core"
        exit 1
    }
else
    echo "::error::Nikki feed package Makefile not found: $NIKKI_MAKEFILE"
    exit 1
fi
# END N1-NIKKI-CLASHOO-CORE

# BEGIN N1-XRAY-GO127
# Xray 26.11.x requires Go >= 1.27. Keep the global Go default unchanged
# for other packages, but pin Xray to the Go 1.27 host toolchain.
XRAY_MAKEFILE="$(readlink -f package/feeds/kiddin9/xray-core/Makefile)"
GO127_MAKEFILE="feeds/packages/lang/golang/golang1.27/Makefile"

if [ ! -f "$XRAY_MAKEFILE" ]; then
    echo "::error::Xray package Makefile not found: $XRAY_MAKEFILE"
    exit 1
fi
if [ ! -f "$GO127_MAKEFILE" ] || ! grep -qx 'GO_VERSION_MAJOR_MINOR:=1.27' "$GO127_MAKEFILE"; then
    echo "::error::OpenWrt packages feed does not provide the expected Go 1.27 toolchain"
    exit 1
fi

if grep -qx 'PKG_BUILD_DEPENDS:=golang/host' "$XRAY_MAKEFILE"; then
    sed -i 's/^PKG_BUILD_DEPENDS:=golang\/host$/PKG_BUILD_DEPENDS:=golang1.27\/host/' "$XRAY_MAKEFILE"
fi
grep -qx 'PKG_BUILD_DEPENDS:=golang1.27/host' "$XRAY_MAKEFILE" || {
    echo "::error::Xray was not pinned to golang1.27/host"
    grep -n '^PKG_BUILD_DEPENDS' "$XRAY_MAKEFILE" || true
    exit 1
}
echo "Verified Xray host toolchain dependency: Go 1.27"
# END N1-XRAY-GO127


