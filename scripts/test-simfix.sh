#!/bin/sh
# 离线验证 files/etc/init.d/simfix 的板型门控与卡槽动作 —— 不需要真机。
#
# 做法：造假的 sysfs(leds) / device-tree(compatible) / qmicli / mmcli / uci，
# 在临时目录里跑真实脚本，断言「哪些板子会被接管、哪些一根 GPIO 都不碰」。
#
# 用法: ./scripts/test-simfix.sh
#       SIMFIX=/path/to/simfix ./scripts/test-simfix.sh   # 验镜像里抽出来的那份
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
SIMFIX=${SIMFIX:-$HERE/files/etc/init.d/simfix}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: 期望 '$3'，实际 '$2'"; fi; }
has()  { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: 日志缺少 '$2'"; fi; }
hasnt(){ if grep -q "$2" "$3" 2>/dev/null; then bad "$1: 不该出现 '$2'"; else ok "$1"; fi; }

# ---------------------------------------------------------------- 环境构造
mkbin() {
	d=$1
	mkdir -p "$d/bin" "$d/state"
	# sleep: 空实现，让等待循环瞬间跑完（脚本里所有 sleep 都是它）
	printf '#!/bin/sh\nexit 0\n' > "$d/bin/sleep"
	cat > "$d/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$SIMFIX_TEST_LOG"
EOF
	cat > "$d/bin/qmicli" <<'EOF'
#!/bin/sh
for a in "$@"; do
	case "$a" in
	--uim-get-card-status)
		echo "  Slot [1]:"
		echo "    Card state: 'present'"
		echo "    Application type: 'usim'"
		echo "    Application ID:"
		echo "      0xa0000000871002"
		if [ -f "$SIMFIX_TEST_STATE/activated" ]; then
			echo "    Application state: 'ready'"
		else
			echo "    Application state: 'detected'"
		fi
		exit 0 ;;
	--uim-change-provisioning-session=*)
		: > "$SIMFIX_TEST_STATE/activated"; echo "success"; exit 0 ;;
	--uim-sim-power-off=*|--uim-sim-power-on=*)
		echo "success"; exit 0 ;;
	esac
done
exit 0
EOF
	cat > "$d/bin/mmcli" <<'EOF'
#!/bin/sh
[ "$1" = "-L" ] && echo "/org/freedesktop/ModemManager1/Modem/0 [GENERIC]"
exit 0
EOF
	cat > "$d/bin/uci" <<'EOF'
#!/bin/sh
# 用法: uci -q get simfix.settings.<key>
key=$(echo "$3" | awk -F. '{print $NF}')
v=$(sed -n "s/^$key=//p" "$SIMFIX_TEST_UCI" 2>/dev/null | head -1)
[ -n "$v" ] && { echo "$v"; exit 0; }
exit 1
EOF
	printf '#!/bin/sh\nexit 0\n' > "$d/bin/ifdown"
	printf '#!/bin/sh\nexit 0\n' > "$d/bin/ifup"
	cat > "$d/mm" <<'EOF'
#!/bin/sh
echo "$1" >> "$SIMFIX_TEST_MMLOG"
exit 0
EOF
	chmod +x "$d"/bin/* "$d"/mm
}

# make_leds <dir> <拓扑: single|four> <初始 trigger> <初始 brightness>
make_leds() {
	mkdir -p "$1/sim:sel"
	echo "$3" > "$1/sim:sel/trigger"
	echo "$4" > "$1/sim:sel/brightness"
	if [ "$2" = "four" ]; then
		for n in sim:en sim:sel2 sim:en2; do
			mkdir -p "$1/$n"
			echo "none" > "$1/$n/trigger"
			echo "0" > "$1/$n/brightness"
		done
	fi
}

# mkcompat <file> <compatible...>
mkcompat() {
	f=$1; shift
	: > "$f"
	for c in "$@"; do printf '%s\000' "$c" >> "$f"; done
}

# ---------------------------------------------------------------- 跑一个用例
# run <name> <compat-file> <leds-dir> <uci-file>
run() {
	d="$TMP/$1"
	mkdir -p "$d"
	mkbin "$d"
	: > "$d/app.log"; : > "$d/mm.log"
	rm -f "$d/state/activated"

	env -i \
		PATH="$d/bin:$PATH" \
		SIMFIX_COMPAT="$2" \
		SIMFIX_LEDS="$3" \
		SIMFIX_QMI=/dev/null \
		SIMFIX_MM="$d/mm" \
		SIMFIX_PIDFILE="$d/simfix.pid" \
		SIMFIX_TEST_LOG="$d/app.log" \
		SIMFIX_TEST_STATE="$d/state" \
		SIMFIX_TEST_UCI="$4" \
		SIMFIX_TEST_MMLOG="$d/mm.log" \
		sh -c ". '$SIMFIX'; start" >/dev/null 2>&1

	i=0
	while [ -e "$d/simfix.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

printf '\n\033[1m=== simfix 离线验证 ===\033[0m\n'

# ---------------------------------------------------------------- 1. sp970
printf '\n[1] sp970（单选择线，compatible=gexing,sp970）—— 应接管\n'
mkleds="$TMP/leds-sp970"; mkdir -p "$mkleds"; make_leds "$mkleds" single usb-gadget 1
mkcompat "$TMP/compat-sp970" "gexing,sp970" "qcom,msm8916"
printf 'enabled=1\nslot=0\nforce=0\nmax_wait=360\nstable_need=20\npower_cycle=1\ntries=3\n' > "$TMP/uci-sp970"
run sp970 "$TMP/compat-sp970" "$mkleds" "$TMP/uci-sp970"
check "sim:sel 被钉到实体卡槽" "$(cat "$mkleds/sim:sel/brightness")" "0"
check "usb-gadget 触发器被解绑" "$(cat "$mkleds/sim:sel/trigger")" "none"
has   "完成 UIM 激活" "sim activated ok" "$TMP/sp970/app.log"
has   "停过 ModemManager" "^stop$" "$TMP/sp970/mm.log"
has   "启回 ModemManager" "^start$" "$TMP/sp970/mm.log"

# ---------------------------------------------------------------- 2. jz02
printf '\n[2] jz02v10（四线双卡槽，compatible=thwc,jz02v10）—— 必须不动\n'
mkleds="$TMP/leds-jz02"; mkdir -p "$mkleds"; make_leds "$mkleds" four usb-gadget 1
mkcompat "$TMP/compat-jz02" "thwc,jz02v10" "qcom,msm8916"
printf 'enabled=1\nslot=0\nforce=0\nmax_wait=360\nstable_need=20\npower_cycle=1\ntries=3\n' > "$TMP/uci-jz02"
run jz02 "$TMP/compat-jz02" "$mkleds" "$TMP/uci-jz02"
check "sim:sel 保持原电平(1=on)" "$(cat "$mkleds/sim:sel/brightness")" "1"
check "触发器未被改动" "$(cat "$mkleds/sim:sel/trigger")" "usb-gadget"
check "没有停/启 ModemManager" "$(wc -l < "$TMP/jz02/mm.log" | tr -d ' ')" "0"
check "没有碰 sim:en2" "$(cat "$mkleds/sim:en2/brightness")" "0"
has   "日志说明跳过原因" "is not gexing-sp970" "$TMP/jz02/app.log"

# ---------------------------------------------------------------- 3. jz02 + force
printf '\n[3] jz02v10 + force=1 —— 四线拓扑仍是硬门控，必须不动\n'
mkleds="$TMP/leds-jz02f"; mkdir -p "$mkleds"; make_leds "$mkleds" four usb-gadget 1
printf 'enabled=1\nslot=0\nforce=1\nmax_wait=360\nstable_need=20\npower_cycle=1\ntries=3\n' > "$TMP/uci-jz02f"
run jz02force "$TMP/compat-jz02" "$mkleds" "$TMP/uci-jz02f"
check "force 也不动 sim:sel" "$(cat "$mkleds/sim:sel/brightness")" "1"
check "force 也不停 ModemManager" "$(wc -l < "$TMP/jz02force/mm.log" | tr -d ' ')" "0"

# ---------------------------------------------------------------- 4. 停用
printf '\n[4] sp970 + enabled=0 —— 应完全不动\n'
mkleds="$TMP/leds-off"; mkdir -p "$mkleds"; make_leds "$mkleds" single usb-gadget 1
printf 'enabled=0\nslot=0\nforce=0\n' > "$TMP/uci-off"
run off "$TMP/compat-sp970" "$mkleds" "$TMP/uci-off"
check "sim:sel 未被写" "$(cat "$mkleds/sim:sel/brightness")" "1"
check "未启动 worker" "$(wc -l < "$TMP/off/mm.log" | tr -d ' ')" "0"

# ---------------------------------------------------------------- 5. 语法
printf '\n[5] 语法检查\n'
if sh -n "$SIMFIX" 2>/dev/null; then ok "sh -n 通过"; else bad "sh -n 失败"; fi
if grep -q "sim:sel" "$SIMFIX"; then ok "脚本引用了 sim:sel"; else bad "脚本未引用 sim:sel"; fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
	printf '\033[1;32m全部通过\033[0m\n'
	exit 0
fi
printf '\033[1;31m%d 项失败\033[0m\n' "$FAIL"
exit 1
