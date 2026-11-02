#!/bin/bash
# MSM8916-OpenWrt-CI —— jz02v10 / sp970v11 (MSM8916 4G Modem Stick) 云编译 / 本地构建两用脚本
#
# 用法:
#   ./build.sh                      # 完整构建，产物在 workspace/openwrt/bin/targets/
#   MODEL=sp970v11 ./build.sh       # 指定机型（默认 jz02v10）
#   JOBS=8 ./build.sh               # 限制并行
#   WIFI_SSID=MyHome WIFI_PSK=xxx ./build.sh
#   ROOT_PASSWORD=xxx ./build.sh    # 设备 root 密码（生成哈希烧进固件）
#   LAN_IP=192.168.66.1 ./build.sh  # LAN 地址（默认 192.168.1.1，上游原值）
#
# 可配环境变量:
#   MODEL            机型，需存在 configs/<model>.diffconfig（默认 jz02v10）
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
#   5. tools/flock 在 runner 上出现过"下载 flock tarball"版本且 dl 拉取失败
#      -> 统一强制为树内编译（vendored），不再依赖任何 tarball
#   6. export PKG_SOURCE_VERSION 会污染所有未声明 PKG_SOURCE 的包/工具
#      （download.mk 默认 "$(PKG_NAME)-$(PKG_VERSION).tar.zst"）
#      -> smsrelay 版本改为 sed 直接写进包 Makefile
set -euo pipefail
cd "$(dirname "$0")"

WORK=${WORK:-$PWD/workspace}
IMMORTALWRT_REF=${IMMORTALWRT_REF:-89f1ef18c888f841633f19f92655ee4b7f7716a4}
ACTIONS_REPO=${ACTIONS_REPO:-xuxin1955/Actions}
SMSRELAY_REF=${SMSRELAY_REF:-openwrt}
SMSRELAY_REPO=${SMSRELAY_REPO:-zhoufla/SMSRelay8916}
LAN_IP=${LAN_IP:-192.168.1.1}
MODEL=${MODEL:-jz02v10}
JOBS=${JOBS:-$(nproc)}
REPO_DIR=$(pwd)

# 机型校验与设备树映射（新增机型：加 configs/<model>.diffconfig + 这里一行）
[ -f "$REPO_DIR/configs/$MODEL.diffconfig" ] || { echo "未知机型: $MODEL（缺 configs/$MODEL.diffconfig）"; exit 1; }
case "$MODEL" in
	jz02v10)  DTS=msm8916-thwc-jz02v10 ;;
	sp970v11) DTS=msm8916-gexing-sp970 ;;
	*)        DTS="" ;;
esac

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. 依赖检查
MISSING=0
for c in git gcc g++ make rsync unzip curl perl python3 xz bison flex gawk; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; MISSING=1; }
done
[ "$MISSING" = 1 ] && { echo "请先安装构建依赖（见 README）"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"

# ---------------------------------------------------------------- 1. 源码
log "1/10 克隆 ImmortalWrt @ ${IMMORTALWRT_REF:0:10}"
if [ ! -d openwrt ]; then
    git init -q openwrt && cd openwrt
    git remote add origin https://github.com/immortalwrt/immortalwrt
    git fetch -q --depth 1 origin "$IMMORTALWRT_REF"
    git checkout -q FETCH_HEAD
    cd ..
fi
# 检出身份自检：实际 HEAD 必须等于 pin，若 runner 拿到别的树，在日志里立即暴露
ACTUAL_REF=$(git -C openwrt rev-parse HEAD 2>/dev/null || echo unknown)
[ "$ACTUAL_REF" = "$IMMORTALWRT_REF" ] || \
    echo "::warning::ImmortalWrt 实际检出 $ACTUAL_REF ≠ pin $IMMORTALWRT_REF"

log "2/10 应用 msm89xx target（$ACTIONS_REPO）"
if [ ! -d actions ]; then
    git clone -q --depth 1 "https://github.com/$ACTIONS_REPO" actions
fi
cp -rf actions/scripts/msm89xx/target/.   openwrt/target/
cp -rf actions/scripts/msm89xx/package/.  openwrt/package/
cp -rf actions/scripts/msm89xx/toolchain/. openwrt/toolchain/
test -f openwrt/target/linux/msm89xx/Makefile
[ -z "$DTS" ] || test -f "openwrt/target/linux/msm89xx/dts/$DTS.dts"

cd openwrt

log "3/10 feeds（固定 commit）"
cp "$REPO_DIR/configs/feeds.conf" feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

log "4/10 已知坑修补"
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

# 坑 5：make download 依赖 tools/flock/compile（staging 缺 flock 二进制时先编它）。
# 若树上的 tools/flock 是"下载 flock-2.18.tar.zst"的版本且 dl 拉取失败，
# make download 第一步就会挂。这里无条件落盘 vendored Makefile + src/flock.c，
# 让 flock 永远树内编译，彻底绕开 tarball 下载（幂等，pin 树本就是此内容）。
if ! [ -f tools/flock/src/flock.c ]; then
    curl -fsSL --retry 3 \
        "https://raw.githubusercontent.com/immortalwrt/immortalwrt/$IMMORTALWRT_REF/tools/flock/src/flock.c" \
        -o tools/flock/src/flock.c
fi
cat > tools/flock/Makefile <<'FLOCKMK'
#
# Copyright (C) 2006-2012 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#
include $(TOPDIR)/rules.mk

PKG_NAME := flock
PKG_VERSION := 2.18
PKG_RELEASE := 1

# 坑 6 的双保险：显式清空源码变量。即使外部再出现 PKG_SOURCE_VERSION
# 一类环境变量，download.mk 的 "?= 默认 tarball" 与 unpack 均不会触发，
# flock 永远走下方 src/ 树内编译。
PKG_SOURCE :=
PKG_SOURCE_URL :=

include $(INCLUDE_DIR)/host-build.mk

HOSTCC := $(HOSTCC_NOCACHE)
HOSTCXX := $(HOSTCXX_NOCACHE)

define Host/Compile
	mkdir -p $(HOST_BUILD_DIR)
	$(HOSTCC) $(HOST_CFLAGS) -o $(HOST_BUILD_DIR)/flock src/flock.c
endef

define Host/Install
	$(INSTALL_BIN) $(HOST_BUILD_DIR)/flock $(STAGING_DIR_HOST)/bin/
endef

define Host/Clean
	rm -f $(STAGING_DIR_HOST)/bin/flock
endef

$(eval $(call HostBuild))
FLOCKMK
echo "   tools/flock -> 树内编译（vendored，不依赖 dl tarball）"

log "5/10 LAN 地址 -> $LAN_IP"
sed -i "s/192\.168\.1\.1/$LAN_IP/g" package/base-files/files/bin/config_generate
sed -i "s/ucidef_set_interface_lan 'eth0'/ucidef_set_interface_lan 'br-lan'/" \
    package/base-files/files/etc/board.d/99-default_network

# ---------------------------------------------------------------- 6. 覆盖层
log "6/10 files 覆盖层（厂商 files-8916 + 本仓库定制）"
rm -rf files
cp -r "$WORK/actions/scripts/files-8916" files
cp -r "$REPO_DIR/files" .

# ---------------------------------------------------------------- 7. 基带固件
# MSM8916 基带（MBA+MPSS）是高通闭源固件，来自设备原厂 modem 分区。
# 项目内置 firmware/<model>/（xz）优先；本地没有对应机型时回退到
# openstick feed 的远程固件包（lkiuyu/qcom-firmware），保持上游行为。
log "7/10 基带固件（$MODEL）"
if [ -f "$REPO_DIR/firmware/$MODEL/mba.mbn.xz" ] && [ -f "$REPO_DIR/firmware/$MODEL/modem.mdt.xz" ]; then
	mkdir -p files/lib/firmware
	for fw in "$REPO_DIR/firmware/$MODEL"/*.xz; do
		xz -dc "$fw" > "files/lib/firmware/$(basename "${fw%.xz}")"
	done
	# 从 DEVICE_PACKAGES 摘掉远程 modem 固件包，避免重复分发
	sed -i "s/ qcom-msm8916-modem-openstick-$MODEL-firmware//" \
		target/linux/msm89xx/image/msm8916.mk
	echo "   使用项目内置基带（$(ls "$REPO_DIR/firmware/$MODEL"/*.xz | wc -l) 个文件 -> files/lib/firmware/）"
else
	echo "   firmware/$MODEL 不存在，改用远程 openstick feed 基带"
fi

# 无线凭据：有 WIFI_SSID/WIFI_PSK 就渲染，否则生成未配置版（设备靠 LTE/USB）
log "8/10 渲染无线配置"
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

# ---------------------------------------------------------------- 9. smsrelay
if [ "${SKIP_SMSRELAY:-0}" != "1" ]; then
    log "9/10 安装 smsrelay 软件包（$SMSRELAY_REPO@$SMSRELAY_REF）"
    if [ ! -d smsrelay ]; then
        git clone -q --depth 1 -b "$SMSRELAY_REF" "https://github.com/$SMSRELAY_REPO" smsrelay
    fi
    # 标准包：包目录（Makefile + files 覆盖层）放进构建树，Go 源码由构建树
    # 自己从 GitHub 拉取并在构建树内编译（openwrt/Makefile，出 ipk）。
    # 坑 6：绝不能 export PKG_SOURCE_VERSION —— make 会把它当全局变量，
    # download.mk 见到它就给所有未声明 PKG_SOURCE 的包/工具默认
    # "下载 $(PKG_NAME)-$(PKG_VERSION).tar.zst"（tools/flock 首当其冲）。
    # 改为直接把分支 HEAD 写进包 Makefile：跟随分支最新且无副作用。
    SMSRELAY_HEAD=$(git -C smsrelay rev-parse HEAD)
    sed -i "s|^PKG_SOURCE_VERSION?=.*|PKG_SOURCE_VERSION:=$SMSRELAY_HEAD|" \
        smsrelay/openwrt/Makefile
    rm -rf package/smsrelay
    cp -a smsrelay/openwrt package/smsrelay
fi

# ---------------------------------------------------------------- 10. 编译
log "10/10 配置与编译（$MODEL）"
cp "$REPO_DIR/configs/$MODEL.diffconfig" .config
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
