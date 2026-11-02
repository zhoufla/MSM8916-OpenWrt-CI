#!/bin/sh
# 从真机提取基带固件到 firmware/<model>/
#
# 设备需已运行 openstick / ImmortalWrt（/lib/firmware 下有 mba.mbn + modem.*），
# 且可 root 登录。提取的是设备正在实际运行的基带，比社区 dump 更可信
# （实测 sp970v11 真机与社区 dump 有 4 个文件不同）。
#
# 用法:
#   FW_PASS=<root密码> ./scripts/pull-modemfw.sh <model> <host>
#   例: FW_PASS=xxx ./scripts/pull-modemfw.sh jz02v10 192.168.1.1
#
# 密码仅经环境变量进入脚本（运行期生成 askpass），不落盘、不进仓库。
# 依赖: ssh tar md5sum xz
set -eu

[ $# -eq 2 ] || { echo "用法: FW_PASS=<root密码> $0 <model> <host>"; exit 1; }
MODEL=$1
HOST=$2
: "${FW_PASS:?需要 FW_PASS 环境变量提供设备 root 密码}"

for c in ssh tar md5sum xz; do
	command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; exit 1; }
done

ROOT=$(pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\necho "$FW_PASS"\n' > "$TMP/askpass"
chmod 700 "$TMP/askpass"
export SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HOST"

mkdir -p "$TMP/raw"
echo "==> 从 $HOST 提取基带 ($MODEL)"
$SSH 'cd /lib/firmware && tar cf - mba.mbn modem.mdt modem.b[0-9]*' | tar xf - -C "$TMP/raw"
$SSH 'cd /lib/firmware && md5sum mba.mbn modem.mdt modem.b[0-9]*' > "$TMP/device.md5"
( cd "$TMP/raw" && md5sum -c "$TMP/device.md5" --quiet ) || {
	echo "::error::传输校验失败"; exit 1; }

# 校验通过才替换本地固件
rm -rf "firmware/$MODEL"
mkdir -p "firmware/$MODEL"
n=0
for f in "$TMP/raw"/*; do
	xz -T0 -9 -c "$f" > "firmware/$MODEL/$(basename "$f").xz"
	n=$((n + 1))
done
echo "    $n 个文件 -> firmware/$MODEL/（md5 与设备端逐文件一致）"
