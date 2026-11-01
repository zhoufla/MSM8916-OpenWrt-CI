#!/bin/bash
# MSM8916-OpenWrt-CI —— jz02v10 (Zhihe 4G Modem Stick) 云编译 / 本地构建两用脚本
#
# 用法:
#   ./build.sh                      # 完整构建，产物在 workspace/openwrt/bin/targets/
#   JOBS=8 ./build.sh               # 限制并行
#   WIFI_SSID=MyHome WIFI_PSK=xxx ./build.sh
#   ROOT_PASSWORD=xxx ./build.sh    # 设备 root 密码（生成哈希烧进固件）
#   LAN_IP=192.168.66.1 ./build.sh  # LAN 地址（默认 192.168.1.1，上游原值）
#
# 可配环境变量:
#   IMMORTALWRT_REF  ImmortalWrt commit（默认与首次成功构建一致）
#   ACTIONS_REPO     msm89xx target 所在仓库（默认 xuxin1955/Actions）
#   SMSRELAY_REF     SMSRelay8916 分支（默认 openwrt）
#   SKIP_SMSRELAY=1  不编译短信网关（调试用）
#
# 已知坑（均已内置处理）:
#   1. openstick feeds 的 gc 包 PKG_MIRROR_HASH 随构建机 git 版本变化 -> skip 校验
#   2. firewall4 fullcone 补丁只在上游 pin 为旧 commit 时适用 -> 按版本判断
#   3. mkbootimg 生成 boot.img 必需，runner 默认没有 -> deb 解包到 ~/.local/bin
#   4. -j$(nproc) 编内核偶发竞态 -> 整体失败后单独重编 target/linux 再续
set -euo pipefail
cd "$(dirname "$0")"

WORK=${WORK:-$PWD/workspace}
IMMORTALWRT_REF=${IMMORTALWRT_REF:-89f1ef18c888f841633f19f92655ee4b7f7716a4}
ACTIONS_REPO=${ACTIONS_REPO:-xuxin1955/Actions}
SMSRELAY_REF=${SMSRELAY_REF:-openwrt}
SMSRELAY_REPO=${SMSRELAY_REPO:-zhoufla/SMSRelay8916}
LAN_IP=${LAN_IP:-192.168.1.1}
JOBS=${JOBS:-$(nproc)}
REPO_DIR=$(pwd)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. 依赖检查
MISSING=0
for c in git gcc g++ make rsync unzip curl perl python3 bison flex gawk; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; MISSING=1; }
done
[ "$MISSING" = 1 ] && { echo "请先安装构建依赖（见 README）"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"

# ---------------------------------------------------------------- 1. 源码
log "1/9 克隆 ImmortalWrt @ ${IMMORTALWRT_REF:0:10}"
if [ ! -d openwrt ]; then
    git init -q openwrt && cd openwrt
    git remote add origin https://github.com/immortalwrt/immortalwrt
    git fetch -q --depth 1 origin "$IMMORTALWRT_REF"
    git checkout -q FETCH_HEAD
    cd ..
fi

log "2/9 应用 msm89xx target（$ACTIONS_REPO）"
if [ ! -d actions ]; then
    git clone -q --depth 1 "https://github.com/$ACTIONS_REPO" actions
fi
cp -rf actions/scripts/msm89xx/target/.   openwrt/target/
cp -rf actions/scripts/msm89xx/package/.  openwrt/package/
cp -rf actions/scripts/msm89xx/toolchain/. openwrt/toolchain/
test -f openwrt/target/linux/msm89xx/Makefile
test -f openwrt/target/linux/msm89xx/dts/msm8916-thwc-jz02v10.dts

cd openwrt

log "3/9 feeds（固定 commit）"
cp "$REPO_DIR/configs/feeds.conf" feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

log "4/9 已知坑修补"
# 坑 2：firewall4 fullcone 补丁仅适用于旧 pin
FW4_SRC="$WORK/actions/scripts/msm89xx/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
FW4_VER=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' package/network/config/firewall4/Makefile)
if [ "$FW4_VER" = "bac1d656e09b48e542f860844fe91cbba82abae2" ] && [ -f "$FW4_SRC" ]; then
    mkdir -p package/network/config/firewall4/patches
    cp -f "$FW4_SRC" package/network/config/firewall4/patches/
    echo "   firewall4 fullcone patch applied"
else
    rm -f package/network/config/firewall4/patches/001-*.patch
    echo "   firewall4 pin=${FW4_VER:-unknown}，跳过 fullcone 补丁"
fi
# 坑 1：gc 的 tar 哈希与构建机 git 版本相关，跳过校验（源码来自固定 commit）
for mk in $(find feeds/openstick -name Makefile -path "*gc*"); do
    if grep -q '^PKG_MIRROR_HASH:=.\+' "$mk"; then
        sed -i 's|^PKG_MIRROR_HASH:=.\+|PKG_MIRROR_HASH:=skip|' "$mk"
        echo "   gc hash -> skip ($mk)"
    fi
done
# libnftnl 新 gcc 的 -Werror 兼容
grep -q 'incompatible-pointer-types' package/libs/libnftnl/Makefile || \
    sed -i '/^TARGET_CFLAGS += \$(FPIC)/a TARGET_CFLAGS += -Wno-error=incompatible-pointer-types' package/libs/libnftnl/Makefile
# image.mk 去掉 DTC 对 graph_child_address 的报错
sed -i '/Wno-graph_child_address/d' include/image.mk

log "5/9 LAN 地址 -> $LAN_IP"
sed -i "s/192\.168\.1\.1/$LAN_IP/g" package/base-files/files/bin/config_generate
sed -i "s/ucidef_set_interface_lan 'eth0'/ucidef_set_interface_lan 'br-lan'/" \
    package/base-files/files/etc/board.d/99-default_network

# ---------------------------------------------------------------- 6. 覆盖层
log "6/9 files 覆盖层（厂商 files-8916 + 本仓库定制）"
rm -rf files
cp -r "$WORK/actions/scripts/files-8916" files
cp -r "$REPO_DIR/files" .

# 无线凭据：有 WIFI_SSID/WIFI_PSK 就渲染，否则生成未配置版（设备靠 LTE/USB）
log "7/9 渲染无线配置"
ENV_WIFI_SSID="${WIFI_SSID:-}" ENV_WIFI_PSK="${WIFI_PSK:-}" ENV_WIFI_ENC="${WIFI_ENC:-}" \
    OUT="$PWD/files/etc/config/wireless" \
    bash "$REPO_DIR/scripts/gen-wireless.sh"
# 防泄漏：模板占位符必须已被渲染（未提供凭据时替换为未配置值，不会留占位符）
if grep -q "@WIFI_SSID@\|@WIFI_PSK@" files/etc/config/wireless; then
    echo "::error::wireless 渲染不完整（残留占位符）"; exit 1
fi

# root 密码（可选；仓库内只存占位符，哈希现场生成）
if [ -n "${ROOT_PASSWORD:-}" ]; then
    H=$(openssl passwd -5 "$ROOT_PASSWORD")
    sed -i "s|@ROOT_PASSWORD_HASH@|$H|" files/etc/uci-defaults/00-root-password
    echo "   root password hash injected"
fi

# ---------------------------------------------------------------- 8. smsrelay
if [ "${SKIP_SMSRELAY:-0}" != "1" ]; then
    log "8/9 编译 SMSRelay（$SMSRELAY_REPO@$SMSRELAY_REF）"
    if [ ! -d smsrelay ]; then
        git clone -q --depth 1 -b "$SMSRELAY_REF" "https://github.com/$SMSRELAY_REPO" smsrelay
    fi
    ( cd smsrelay
      CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
      go build -trimpath \
      -ldflags "-s -w -X main.Version=$(git describe --tags --always 2>/dev/null || echo openwrt)" \
      -o "$WORK/openwrt/files/usr/bin/smsrelay" ./cmd/smsrelay )
    ls -lh files/usr/bin/smsrelay
fi

# ---------------------------------------------------------------- 9. 编译
log "9/9 配置与编译"
cp "$REPO_DIR/configs/jz02v10.diffconfig" .config
make defconfig

# 坑 3：mkbootimg（deb 解包到用户目录，不依赖 root）
export PATH="$HOME/.local/bin:$PATH"
if ! command -v mkbootimg >/dev/null 2>&1; then
    mkdir -p ~/.local/bin /tmp/mkb && cd /tmp/mkb
    curl -sL -o mk.deb "https://github.com/xuxin1955/depend_ubuntu2204_openwrt/releases/download/ubuntu_26.04_LTS_mkbootimg/mkbootimg_34.0.5-12build1_all.deb"
    dpkg-deb -x mk.deb root
    cp root/usr/bin/mkbootimg root/usr/bin/unpack_bootimg ~/.local/bin/
    chmod +x ~/.local/bin/mkbootimg ~/.local/bin/unpack_bootimg
    cd "$WORK/openwrt"
fi

make -j"$JOBS" download || make download V=s

set +e
make -j"$JOBS"
RC=$?
if [ $RC -ne 0 ]; then
    echo "!! 并行构建失败（多为内核编译竞态），单线程重编内核续跑"
    make target/linux/compile V=s -j1
    make -j"$JOBS"
    RC=$?
fi
set -e
[ $RC -ne 0 ] && { echo "::error::构建失败"; exit $RC; }

log "产物"
ls -lh bin/targets/msm89xx/msm8916/ | grep -E "img|bin|manifest" || true
echo "完成。"
