#!/bin/sh
# gen-wireless.sh —— 渲染 openwrt 无线配置（files/etc/config/wireless）
#
# 凭据来源（优先级从高到低）：
#   1. 环境变量 WIFI_SSID / WIFI_PSK / WIFI_ENC（CI 用 GitHub Secrets 注入）
#   2. secrets/wifi.conf 文件（KEY=VALUE；本地开发用，已在 .gitignore）
#   3. 都没有 -> 生成「未配置」版本：radio0 保留、sta disabled，
#      设备靠 LTE/USB 照常工作
#
# 用法：
#   scripts/gen-wireless.sh                        # 渲染到 ./files/etc/config/wireless
#   OUT=/path/files/etc/config/wireless scripts/gen-wireless.sh
#   scripts/gen-wireless.sh --check                # 只校验模板，不写文件
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TPL="$REPO_ROOT/jz02/wireless.tpl"
SECRET="$REPO_ROOT/secrets/wifi.conf"
OUT="${OUT:-$REPO_ROOT/files/etc/config/wireless}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -f "$TPL" ] || { echo "FATAL: 模板缺失 $TPL" >&2; exit 1; }
[ "$CHECK_ONLY" = 1 ] && { echo "check: 模板 OK ($TPL)"; exit 0; }

# 1) 文件里的值
WIFI_SSID=""; WIFI_PSK=""; WIFI_ENC="psk2"
if [ -f "$SECRET" ]; then
    # shellcheck disable=SC1090
    . "$SECRET"
fi
# 2) 环境变量优先（CI Secrets）
if [ -n "${ENV_WIFI_SSID:-}" ]; then WIFI_SSID="$ENV_WIFI_SSID"; fi
if [ -n "${ENV_WIFI_PSK:-}" ]; then WIFI_PSK="$ENV_WIFI_PSK"; fi
if [ -n "${ENV_WIFI_ENC:-}" ]; then WIFI_ENC="$ENV_WIFI_ENC"; fi

if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
    WIFI_DISABLED=0
    MODE_DESC="已配置"
else
    # 未配置：ssid/key 渲染成空串。
    # 注意：这里不能填回 "@WIFI_SSID@" 这类占位符本身 —— sed 会把占位符替换成
    # 同样的字符串，产物里就留下 @WIFI_SSID@，build.sh 第 8 步的残留检查
    # （见 build.sh "wireless 渲染不完整"）会直接失败。
    WIFI_SSID=""
    WIFI_PSK=""
    WIFI_DISABLED=1
    MODE_DESC="未配置（设备靠 LTE/USB 管理）"
fi

mkdir -p "$(dirname "$OUT")"
sed -e "s|@WIFI_SSID@|$WIFI_SSID|g" \
    -e "s|@WIFI_PSK@|$WIFI_PSK|g" \
    -e "s|@WIFI_ENC@|$WIFI_ENC|g" \
    -e "s|@WIFI_DISABLED@|$WIFI_DISABLED|g" \
    "$TPL" > "$OUT"

# 含密码的配置只给 root
chmod 600 "$OUT" 2>/dev/null || true
echo "wireless 渲染完成 -> $OUT ($MODE_DESC)"
