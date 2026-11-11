# JZ02 TSENS 温度诊断与验证

## 实机故障

2026-11-11，JZ02-V10、Linux 6.18.55：只有 `pm8916-thermal`（约 34°C），
CPU、GPU、modem 温区未注册。启动报 `tsens_probe: calibration failed`、`-ENOENT`。
TSENS、QFPROM 均已编入，设备树中存在独立校准项和对应温区。
另有此前手动 bind 在 `init_common()` 入口发生 Oops 的记录。

## 补丁范围

`patches/6.18/990-qcom-tsens-calibration-errors.patch` 由 `build.sh` 接入：

- 设备树声明 `mode` 时直接使用独立校准项，保留错误与 `-EPROBE_DEFER`；
  旧设备树继续使用旧校准接口。
- 校准读取失败时记录具体 cell 名称和错误，不修改校准数值或跳过校准。
- 移除 `init_common()` 的 `__init`，修复初始化内存释放后重新探测的崩溃。
  参考[上游补丁投稿](https://lists.openwall.net/linux-kernel/2026/11/04/2167)。

这是错误处理修正和诊断补丁；首次校准失败的原始错误尚未取到，不能视为温度已恢复。

## 验证边界

本机按要求不编译。补丁应用与脚本语法检查不代表交叉编译或实机测试通过。
已验证：Linux 6.18、6.18.55 源码的 `patch --dry-run --fuzz=0`；
Linux 6.18.55 临时源码副本实际应用成功；LF 检出形式的 `build.sh` 语法通过；
补丁复制、重复执行和版本选择检查通过，保留已有上游补丁。
后续使用 JZ02 云编译产物，经确认后启动新内核，读取：

```sh
uname -a
dmesg | grep -Ei 'tsens|calibration|qfprom|nvmem'
for z in /sys/class/thermal/thermal_zone*; do
    echo "$z"
    cat "$z/type" "$z/temp"
done
```

成功标准：CPU 两组、GPU、camera、modem 与 PM8916 共六个温区可读，
启动无 TSENS 校准失败、无新增 Oops。若仍失败，根据 `failed to read calibration cell`
的具体名称和错误继续定位。不要用当前旧内核上的手动 bind 替代新内核验证。
