#!/bin/bash
# 基带 NV（modemst1 / modemst2）管理
#
# 背景：短信走 CS 域。有些设备的 modemst 里 Service domain preference 是
# ps-only（只注册数据域），表现是「能上网、收发不了短信」——mmcli --send
# 会卡满 30 秒超时，AT+CMGS 也拿不到 +CMGS 确认。firmware/<model>/nv/
# 存的是真机实测可用的一份（QPST 改过 CS and PS，CS 能注册）。
#
# 用法（仓库根目录执行）：
#   ./scripts/nv.sh check           # 看设备当前 CS/PS 注册状态
#   ./scripts/nv.sh pull  <model>   # 从 adb 设备回读 modemst1/2，压缩入库
#   ./scripts/nv.sh flash <model>   # 解压并 fastboot 刷入（需先 adb reboot bootloader）
#
# WSL 下调 Windows 版 adb/fastboot：
#   export ADB=/mnt/f/wifi/sp970/adb/platform-tools/adb.exe
#   export FB=/mnt/f/wifi/sp970/adb/platform-tools/fastboot.exe
#   脚本用 wslpath 自动转路径，临时文件默认放 /mnt/f 供 Windows 侧读取；
#   可用 NV_TMP=<Windows 可见目录> 覆盖。
#
# 注意：modemst 含 IMEI 与射频校准，属设备专属数据，只放私有仓库、不要外传。

set -euo pipefail

ADB=${ADB:-adb}
FB=${FB:-fastboot}
ACTION=${1:-}
MODEL=${2:-jz02v10}
DIR=$(cd "$(dirname "$0")/.." && pwd)
NV="$DIR/firmware/$MODEL/nv"

to_host() {  # WSL 下把 Linux 路径转成 Windows 路径，其他环境原样返回
    if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else printf '%s\n' "$1"; fi
}
need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }; }

# adb/fastboot 是 Windows 原生程序时，\\wsl$\... 这类 UNC 路径不一定能访问，
# 因此临时文件优先放在 /mnt/f（Windows 侧可见的普通盘符路径）。
host_tmp() {
    local d=${NV_TMP:-}
    if [ -z "$d" ]; then
        if [ -d /mnt/f ] && [ -w /mnt/f ]; then d=/mnt/f/wifi/.nv-flash
        else d=$(mktemp -d); fi
    fi
    mkdir -p "$d"
    printf '%s\n' "$d"
}

check() {
    need "$ADB"
    echo "==> 注册状态"
    $ADB shell 'qmicli -d /dev/wwan0qmi0 --device-open-proxy --nas-get-serving-system 2>/dev/null | grep -iE "CS:|PS:|Registration state"' | tr -d '\r'
    echo "==> 域偏好"
    $ADB shell 'qmicli -d /dev/wwan0qmi0 --device-open-proxy --nas-get-system-selection-preference 2>/dev/null | grep -i "service domain"' | tr -d '\r'
    echo "    正常：CS 'attached' + service domain 'cs-ps'；detached 则短信/电话都不可用"
}

pull() {
    need "$ADB"; need xz
    mkdir -p "$NV"
    tmp=$(host_tmp)
    for spec in "7:modemst1" "8:modemst2"; do
        p=${spec%%:*}; n=${spec##*:}
        echo "==> 读取 /dev/mmcblk0p$p ($n)"
        # 原厂 / QPST 备份均为 1.5MB（3072 扇区），只读这一段以保持与 nv/ 中文件同尺寸。
        $ADB shell "dd if=/dev/mmcblk0p$p of=/tmp/$n.bin bs=512 count=3072 2>/dev/null"
        dev=$($ADB shell "md5sum /tmp/$n.bin" | tr -d '\r' | awk '{print $1}')
        $ADB pull "/tmp/$n.bin" "$(to_host "$tmp/$n.bin")" >/dev/null
        loc=$(md5sum "$tmp/$n.bin" | awk '{print $1}')
        if [ "$dev" != "$loc" ]; then
            echo "!! $n 传输校验失败（设备端 $dev / 本地 $loc）"; exit 1
        fi
        xz -T0 -9 -c "$tmp/$n.bin" > "$NV/$n.bin.xz"
        echo "    $n md5=$loc -> $NV/$n.bin.xz ($(stat -c %s "$NV/$n.bin.xz") 字节)"
        rm -f "$tmp/$n.bin"
    done
}

flash() {
    need "$FB"; need xz
    tmp=$(host_tmp)
    for n in modemst1 modemst2; do
        f="$NV/$n.bin.xz"
        [ -f "$f" ] || { echo "缺少 $f"; exit 1; }
        xz -dc "$f" > "$tmp/$n.bin"
        echo "==> 刷 $n（$(stat -c %s "$tmp/$n.bin") 字节）"
        $FB flash "$n" "$(to_host "$tmp/$n.bin")"
        rm -f "$tmp/$n.bin"
    done
    echo "==> 完成。重启后用 '$0 check' 确认 CS 是否为 attached"
}

case "$ACTION" in
    check) check ;;
    pull)  pull ;;
    flash) flash ;;
    *) sed -n '2,24p' "$0"; exit 1 ;;
esac
