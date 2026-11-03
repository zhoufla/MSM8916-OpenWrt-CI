#!/bin/sh
# modem-guard.sh v4 — 基带启动守护（真实开机版）
#
# 两台真机重启实测暴露的两个问题，v4 针对性修掉：
#   1. "端口出现"不等于成功。SP970 会先出 qmi0，3.4s 后才崩（smd_dsm_memcpy.c:297）。
#      → 必须过稳定性窗口才能判成功。
#   2. 崩溃恢复（crash-recovery）后拿到的是残留的 bam-dmux 通道
#      （日志里 `Channel already open: 0..7`），表现为 at0 挂上 ~39s 后自己掉。
#      → 只要“本次开机崩过”，就要再做一次干净 stop/start 换掉通道。
#
# 判据（实测）：
#   失败 → dmesg 出现 `failed to announce new service`（up 后 0.7ms，与失败 100% 相关）
#   成功 → 三个端口 at0/at1/qmi0 齐全且稳定 STABLE 秒无新崩溃
#
# 安全：最后一次失败时**不再 stop**，modem 留在 running，交回内核 crash-recovery。

R=/sys/class/remoteproc/remoteproc0
QMI=/dev/wwan0qmi0
FIRST_WAIT=45    # 首轮：要给 eMMC 加载留够（实测 10.5s）
RETRY_WAIT=20    # 重试：走 page cache，0.6s 就 up
STABLE=15        # 稳定性窗口：期间不许有新 crash、qmi0 不许消失
STOP_GAP=10      # stop 与 start 之间的间隔
MAX_TRY=${1:-3}
LOG=/root/modem-guard.log    # 落闪存，重启后仍可追溯

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] $*" >> "$LOG"; }

announce_failed() {
    dmesg | tail -n +$((MARK + 1)) 2>/dev/null | grep -aq "failed to announce"
}
crash_count() { dmesg | grep -ac "handling crash"; }
port_count()  { ls /dev/wwan0* 2>/dev/null | wc -l; }

# 0=健康  1=握手失败(stall)  2=窗口内无任何结论  3=崩过/端口不全
check_once() {
    limit=$1
    i=0
    while [ "$i" -lt "$limit" ]; do
        [ -c "$QMI" ] && break
        if [ "$i" -ge 2 ] && announce_failed; then
            return 1
        fi
        i=$((i + 1))
        sleep 1
    done
    [ -c "$QMI" ] || return 2

    c0=$(crash_count)
    j=0
    while [ "$j" -lt "$STABLE" ]; do
        [ -c "$QMI" ] || return 3
        [ "$(crash_count)" != "$c0" ] && return 3
        j=$((j + 1))
        sleep 1
    done

    [ "$(port_count)" -ge 3 ] && return 0
    return 3
}

MARK=$(dmesg | wc -l)
log "start, crash_count=$(crash_count) ports=$(port_count)"

# 开机时等内核自己拉起 modem（最多 25s）；仍离线才代劳
n=0
while [ "$n" -lt 25 ]; do
    [ -c "$QMI" ] && break
    [ "$(cat $R/state 2>/dev/null)" = "running" ] && break
    n=$((n + 1))
    sleep 1
done
if [ "$(cat $R/state 2>/dev/null)" != "running" ] && [ ! -c "$QMI" ]; then
    log "state not running after ${n}s, starting modem ourselves"
    echo start > $R/state 2>/dev/null
fi

try=1
while [ "$try" -le "$MAX_TRY" ]; do
    if [ "$try" -eq 1 ]; then W=$FIRST_WAIT; else W=$RETRY_WAIT; fi

    check_once "$W"
    v=$?

    [ "$v" -eq 0 ] && { log "healthy on attempt $try (ports=$(port_count))"; exit 0; }

    if [ "$v" -eq 2 ]; then
        log "attempt $try: no verdict in ${W}s, leaving modem alone"
        exit 1
    fi

    if [ "$v" -eq 1 ]; then
        log "attempt $try: handshake failed (stall)"
    else
        log "attempt $try: crashed or ports incomplete (crash=$(crash_count) ports=$(port_count))"
    fi

    if [ "$try" -ge "$MAX_TRY" ]; then
        log "last attempt; leaving modem RUNNING for kernel recovery"
        exit 1
    fi

    echo stop > $R/state 2>/dev/null
    sleep "$STOP_GAP"
    echo start > $R/state 2>/dev/null
    log "attempt $try: clean restart issued"
    try=$((try + 1))
done

exit 1
