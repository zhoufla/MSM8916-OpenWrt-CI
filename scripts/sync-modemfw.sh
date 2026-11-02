#!/bin/sh
# 同步原厂基带固件到 firmware/<model>/
#
# 基带（MBA + MPSS）是高通闭源固件，来自各机型原厂系统的 modem 分区；
# openstick 社区把 dump 出的 FAT 镜像托管在 lkiuyu/qcom-firmware。
# 本脚本从固定 commit 重新抽取，保证可复现：
#   1. 下载 openstick-<model>-modem.bin（原厂 modem 分区镜像）
#   2. scripts/fat_extract.py 抽取 mba.mbn + modem.*（小写命名）
#   3. xz -9 压缩入库
#
# 用法:
#   ./scripts/sync-modemfw.sh <model>...      # 例: ./scripts/sync-modemfw.sh jz02v10 sp970v11
#   FW_COMMIT=<commit> ./scripts/sync-modemfw.sh jz02v10   # 覆盖来源 commit
#
# 依赖: curl python3 xz
set -eu

FW_COMMIT=${FW_COMMIT:-e64f8cfd2a3aabe58633609f33e23c5c9d00730e}
BASE="https://raw.githubusercontent.com/lkiuyu/qcom-firmware/$FW_COMMIT"
DIR=$(dirname "$0")

[ $# -ge 1 ] || { echo "用法: $0 <model>..."; exit 1; }
for c in curl python3 xz; do
	command -v "$c" >/dev/null 2>&1 || { echo "缺少命令: $c"; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for model in "$@"; do
	echo "==> $model（来源 qcom-firmware@$FW_COMMIT）"
	curl -fL --retry 3 -o "$TMP/$model.bin" "$BASE/openstick-$model-modem.bin"
	rm -rf "firmware/$model"
	python3 "$DIR/fat_extract.py" "$TMP/$model.bin" "firmware/$model"
	(
		cd "firmware/$model" || exit 1
		for f in *; do
			xz -T0 -9 -f "$f"
		done
	)
	echo "    $(ls "firmware/$model" | wc -l) 个文件 -> firmware/$model/"
done

echo "完成。构建时 build.sh 自动解压到 files/lib/firmware/。"
