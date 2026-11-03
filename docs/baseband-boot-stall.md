# 基带启动崩溃（dog.c:1498 stalled initialization）调查结论

日期：2026-11-03　设备：JZ02（thwc jz02-v10）/ SP970（gexing sp970-v11），msm8916 主线方案

## 现象

开机后约 54s，modem（qcom-q6v5-mss）报 `fatal error received: dog.c:1498: Watchdog
detects stalled initialization`，remoteproc 自动重启基带；部分开机崩 1~5 次（40s 周期）
后稳定，部分开机一次不崩。SP970 表现为 `smd_dsm_memcpy.c:297`，开机 23s 崩 1 次自愈。
崩溃只集中在开机后的窗口，稳定后永不复发（最长观测 3h+）。

## 试验一：换其他机型的基带固件（全部失败，此路不通）

从上游 lkiuyu/qcom-firmware（openstick feed 来源，每个机型为 64MB modem 分区 FAT 镜像，
`scripts/fat_extract.py` 抽取 `mba.mbn + modem.*`）取 6 套固件依次替换 JZ02 并重启观察，
判定标准为"连续 3 次开机 0 崩溃且基带可注册上网"：

| 固件 | 首开崩溃 | 基带可用 |
|---|---|---|
| jz02v10 真机提取（基线） | 0~3 次（约半数开机有崩溃） | ✅ 唯一可用 |
| sp970v11 真机提取 | 5 次 | ❌ |
| uz801 社区 dump | 0 次 | ❌ 射频点不亮，无法注册 |
| mf32 社区 dump | 4 次 | ❌ 无法注册 |
| ufi001b 社区 dump | 1 次 | ❌ 无法注册 |
| dragonboard（高通官方构建） | 4 次，循环重启 | ❌ 最差 |

结论：**外来固件在这块板上要么 dog.c 卡死、要么射频无法校准，jz02v10 真机固件仍是唯一
可用方案。** `firmware/jz02v10/` 与社区 dump 字节级相同（逐文件 md5 一致），勿再尝试换装
其他机型基带。

## 调查二：rmtfs 启动时机假设（证据排除）

rmtfs（S80）启动仅比 MPSS 加载早 ~0.24s，时序余量极薄，曾怀疑崩溃是 modem 等 EFS 服务
超时。验证方法：init 脚本给 rmtfs 加 `-v` 并转发 stdout/stderr 到 syslog，抓崩溃窗口内的
握手日志；同时采集 4 次开机完整 dmesg 对比时间线。

证据链（崩溃开机）：

1. rmtfs `registering services` 早已完成，**整个 40s 停滞窗口内收到请求数为零**
2. 崩溃瞬间唯一活动是 `[RMTFS] bye from 0`（modem 的 QRTR 节点退出）
3. 重试的第 2 次 MPSS 启动才第一次 `open /boot/modem_fs1→fs2→fsg→fsc`，**<1s 全部成功**
4. 崩溃开机的第一次 MPSS 启动没有任何 wwan 端口挂载（at0/at1/qmi0 均未出现）；干净开机
   这些端口在 `is now up` 后 ~1s 内挂载；重试成功后 0.6s 内挂载
5. 崩溃点精确等于 `is now up + 40.05s`（modem 内部看门狗周期 40s），即初始化从第一刻起零进展

**结论：rmtfs 排除。** 卡死发生在 modem 与主机建立任何通信（QRTR/EFS/SMD 端口）之前，
主机侧任何用户态进程都不可能是阻塞者。

## 根因定位与兜底

卡点在 modem 固件内部最早期初始化（建链之前）；结合 6 套固件（含高通官方构建）在同一
位置卡死，最可疑为 RFFE 总线/RFIC 握手等板级硬件边际问题。此问题**无法从主机侧根治**，
现有机制已是正确兜底：

- 内核 remoteproc 自动重试：实测 100% 恢复，重试成功后 0.6s 内通道全通
- smsrelay-keepalive 的"基带未就绪静默等待 + GRACE 宽限"：正确覆盖崩溃窗口
- 业务影响 = 开机就绪时间推迟 0~3 分钟，窗口内短信由运营商 SMSC 重发，不丢

## 复现与观测方法

```sh
# 观测崩溃
dmesg | grep -ac "handling crash"        # 开机 215s 后统计
dmesg | grep -a "fatal error received"

# rmtfs 握手观测（JZ02 已部署 -v 版）
# /etc/init.d/rmtfs: procd_set_param command $PROG -P -r -s -v
#                    procd_set_param stdout 1
#                    procd_set_param stderr 1
logread | grep "rmtfs\["                 # 崩溃窗口内 rmtfs 应为空、bye from 0 后才有 open
```

固件替换安全流程（如需再做固件试验）：候选放 `/lib`（勿放 /tmp，重启即丢）→
`ssh 'cat > file' < local` 传输（设备无 sftp-server）→ md5 校验通过才 `rm -f mba.mbn
modem.mdt modem.b[0-9]*` 并换入 → 同会话 reboot。JZ02 留有整目录备份
`/lib/firmware.bak-jz02`。

## 给社区 issue 的证据要点

- 6 套不同来源固件（含 Qualcomm 官方 dragonboard 构建）首次 MPSS 启动在同一位置停滞，
  首崩时间 53.4~54.5s 高度一致 = `is now up + 40s` 看门狗
- 停滞期间 rmtfs 空闲、无任何 wwan 端口挂载 → 排除"缺用户态服务（rmtfs/qrtr-ns 等）"
  方向，指向 modem 内部/板级硬件
- remoteproc 重试必成，之后永不复发；建议关注 RFFE/RFIC 初始化路径
