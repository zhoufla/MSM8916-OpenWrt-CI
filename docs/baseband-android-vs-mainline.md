# 基带开机停滞：安卓（downstream）与主线（mainline）逐项对照

日期：2026-11-09　对比对象：SP970-B（Android 4.4.4 / downstream 3.10，在线实测）
与 JZ02/SP970（msm8916 主线 6.17/7.0 + openstick DTS）

> 背景结论见 `baseband-boot-stall.md`：主线开机后约 `is now up + 40s`，modem 报
> `dog.c: Watchdog detects stalled initialization`，remoteproc 自动重启；部分开机崩 1~5 次后稳定，
> 稳定后永不复发。本文补齐"为什么同一块板跑安卓不出问题"这一环的实测对照。

## 1. 固件：完全一致（此项排除）

SP970 安卓侧 `/firmware/image/`（modem 分区挂载点）与 OpenWrt CI 内嵌
`firmware/sp970v11/`（解压 .xz 后）**24 个文件逐字节相同**：

```
mba.mbn        2144cd0a0693f1c075327538463e54e1
modem.mdt      f7c4fde30bbfaae7eeec79378422c2f0
modem.b00~b27  22 个段文件，md5 全部一一对应
```

结论：**"安卓能跑是因为用了另一份基带固件"不成立**。两边跑的是同一份 MPSS，
差异只可能在主机侧（内核/DTS/时序）。

## 2. 安卓侧实测启动时序（本次重启抓取）

```
[0.72] pil-q6v5-mss 4080000.qcom,mss: [modem]: Error getting proxy unvoting gpio
[0.72] platform 4080000.qcom,mss: Driver pil-q6v5-mss requests probe deferral
[6.03] pil-q6v5-mss: modem: loading from 0x86800000 to 0x8b300000   (镜像跨 75 MB)
[6.08] pil: MBA boot done                                            (+58 ms)
[6.73] pil-q6v5-mss: modem: Brought out of reset                     (+650 ms，加载 MPSS)
[6.82] pil-q6v5-mss: modem: Power/Clock ready interrupt received      (+91 ms)
[6.82] pil-q6v5-mss: Subsystem error monitoring/handling services are up
[8.68] apr_tal: Modem Is Up                                          (+1.86 s)
```

对照主线：内核打印的 `remote processor 4080000.remoteproc is now up` 出自 remoteproc core，
其前置条件是 `qcom_q6v5_wait_for_start()` 收到 `ready` 中断 —— **与安卓 `Power/Clock ready
interrupt received` 是同一阶段**。

于是两侧的差异被收敛到一个点：
- 安卓：ready 之后 **1.86 s** 服务全部就绪；
- 主线：ready 之后正常开机约 1 s 端口全出；异常开机则 **零进展 40 s** 直到 dog 看门狗。

即：卡死发生在 modem 自己的应用层初始化里，**不在上电/时钟/供电/固件加载**环节
（这些环节安卓用 91 ms 就过了，同一颗芯片、同一份固件）。

## 3. 内存布局对照

安卓（`/proc/iomem` + 开机 CMA 日志）：

```
System RAM        0x80000000-0x85ffffff
保留段            0x86000000-0x8bbfffff（92 MB 全部 no-map）
  modem_adsp CMA  0x86800000 + 78 MiB (0x4e00000)  → 0x8b600000
  wcnss (ION)     0x8b600000 + 6 MiB               → 0x8bc00000
System RAM        0x8bc00000-0x9fffffff
MBA 与 MPSS 同处 modem 区内（加载跨 0x86800000..0x8b300000）
```

主线（`artifacts/jz02v10-6.17-ref.dtb` 实际内容）：

```
tz-apps  0x86000000 +0x300000
smem     0x86300000 +0x100000
hyper    0x86400000 +0x100000
tz       0x86500000 +0x180000
reserved 0x86680000 +0x080000
rmtfs    0x86700000 +0x0e0000
rfsa     0x867e0000 +0x020000
mpss     0x86800000 +0x5500000 (85 MB)  → 0x8bd00000
wcnss    动态 6 MB  → 0x8bd00000        (比安卓高 7 MB)
venus    动态 5 MB  → 0x8c300000
mba      动态 1 MB  → 0x8c800000        (安卓无独立 mba 区)
```

差异：modem 区 85 MB vs 78 MB（镜像实际占 75 MB，两者都有余量）；wcnss 基址整体上移 7 MB；
mba 独立成区。**判断：低概率是根因**（modem 自身基址 0x86800000 两边相同，镜像也在同一基址加载）；
但可作为最便宜的 A/B 项——把 `mpss_mem` 改成 `0x4e00000`、`wcnss_mem` 固定 `reg` 到
`0x8b600000`，即可精确复刻安卓布局。

> **2026-11-10 补充（已排除）**：能正常工作的 ImmortalWrt r35810（内核 6.12.45）镜像，
> 其 boot 分区 DTB 的 reserved-memory 与本表**逐条一致**（`mpss@86800000` 仍是 `0x5500000`，
> wcnss/venus/mba 同样是动态区）。同一份布局既能崩也能不崩 → **内存布局不是变量，本项关闭**。

## 4. 实测结论：安卓 6/6 全部干净（"静默自愈"假设已排除）

2026-11-09 22:47–22:55 连续 5 次冷启动 + 首次抓取的 1 次，共 **6 次采样，全部干净**：

| 轮次 | modem `Power/Clock ready` | `Modem Is Up` | `Restarting modem` |
|---|---|---|---|
| 1–5 | 各 1 次 | 各 1 次 | 各 0 次 |
| 初次抓取 | 1 次 | 1 次 | 0 次 |

**统计口径注意**：`Power/Clock ready` 这条消息 modem 和 wcnss 各打一次，直接 `grep -c`
恒为 2，必须按 `pil-q6v5-mss ... modem:` 限定，否则会误判成"每次重启过一次"。
本次已按限定复核：

```
[ 6.808] pil-q6v5-mss 4080000.qcom,mss: modem: Power/Clock ready interrupt received
[11.342] subsys-pil-tz a21b000.qcom,pronto: wcnss: Power/Clock ready interrupt received
```

若主干侧真的是 p≈0.5 的随机停滞，6 次全干净的概率仅 1.6%。因此
**"安卓其实也崩、只是 subsystem_restart 静默重启没被发现"这个可能性可以排除**：
同一份固件、同一个基址，安卓侧确实是稳定通过的，差异是真实存在的，在主机侧。

### 顺带记录的安卓侧供电快照（后续在 Debian 上可比对）

```
8916_l7   enabled  users=1  1.800 V   ← modem PLL supply（主线 pll-supply 同一条轨）
8916_s2   enabled  users=1  1.100 V
8916_s4   enabled  users=2  1.800 V
8916_s1_corner enabled users=3 corner=5
apc_corner     enabled users=1 corner=4
```

## 4b. 由时序推出的新怀疑点：启动顺序

安卓侧的先后关系是明确的 **modem 先、wifi 后**：

```
[ 6.82] modem ready        → [ 8.79] Modem Is Up
[10.58] wcnss loading      → [11.34] wcnss ready
```

主线棒子上 mss / wcnss 都是由用户态 init 脚本拉起，**顺序取决于脚本排布**。
若 wcnss 先起（或两者交错），modem 初始化期间会与 wcnss 争 CX/MX 投票和
RFFE/共享资源，恰好能解释"零进展 + 重试可愈 + 概率性"。

**验证成本极低**：先在现役日志里看两个 remoteproc 的 `is now up` 先后，
若 wcnss 在前，把 mss 提到前面（或给 mss 启动加 1~2s 独占窗口）再跑 10 次冷启动。

**实测（2026-11-09，JZ02 / ImmortalWrt r35810）**：确实是反的，而且链路查清了——

```
[10.31] a204000.remoteproc is now up     ← S19wpad 触发 wcnss
[20.08] 4080000.remoteproc is now up     ← S80rmtfs（rmtfs -P -r -s，带 -s 才拉起 mss）
```

`/etc/rc.d` 顺序：`S19wpad` → `S60qrtr` → `S70modemmanager` → `S80rmtfs`。
安卓是 `modem 6.81s → wcnss 11.34s`，本机完全颠倒。

但同一台机器连跑 6 次冷启动 **全部干净**（见 §8），说明"顺序反了"**不是充分条件**，
本假设相应降级：除非另有触发因素，单改顺序大概率看不到收益。

## 5. 无论根因如何都值得做的改进：主动重启代替死等

现状：基带卡死后由 modem 内部看门狗在 **40 s** 才发现，remoteproc 再恢复；
最坏情况崩 5 次 → 开机到可用被推迟 3 分钟以上。

可做的：在 `is now up` 之后 6~8 s 检查端口是否出现，没有就主动
`echo stop > /sys/class/remoteproc/remoteproc0/state` / `echo start ...`，
把单次恢复时间从 40 s+ 压到 ~8 s。这与安卓侧 `subsystem_restart` 的隐性行为等价，
且完全在用户态，OpenWrt / Debian 通用。

已落地（2026-11-09）：

| 文件 | 作用 |
|---|---|
| `files/usr/bin/modem-recover` | 兜底脚本本体（POSIX sh，单一来源，两套系统共用） |
| `files/etc/init.d/modem-recover` | OpenWrt procd 一次性任务，`START=99`，不阻塞开机 |
| `jz02-firmware/scripts/device/modem-recover.service` | Debian systemd oneshot 单元 |
| `jz02-firmware/scripts/device/modem-recover.README.md` | Debian 安装与验证步骤 |

默认 `-n 3 -w 12`：正常开机只在 syslog 留一行；踩到 stalled init 时约 10 s 内恢复。
排查期间可用 `-n 0` 切成只观测。

## 6. 若要把根因钉死

需要 Q6 自己的视角：崩溃时抓 `/sys/class/devcoredump/devcd*/data`（需 `CONFIG_DEV_COREDUMP`），
从 dump 里的 PC/LR 判断停在哪个模块；配合 ttyMSM0 串口可进一步确认。
这是唯一能给出"卡在哪一行"的路径。

## 7. 实验顺序（2026-11-10 修订：两项已排除，优先级重排）

| 序 | 实验 | 改动量 | 判据 |
|---|---|---|---|
| 1 | **内核版本对照**：在会崩的机器上换 6.12.x 内核（或直接跑 §8 的 r35810 镜像），看是否复现 | 换内核 / 换镜像 | 若 6.12 不崩 → 锁定 6.17 回归，再 bisect 6.12→6.17 的 q6v5/rpmpd/smd 改动 |
| 2 | `pm8916_l7` 加 `regulator-always-on`（modem PLL 提前稳定） | DTS 1 行 | 10 次冷启动 0/10 |
| 3 | `q6v5_start()` 在释放复位前加 `usleep_range(2000,3000)` | 内核 3 行 | 0/10 |
| 4 | 抓 devcoredump 读 Q6 的 PC/LR | 无（只读） | 定位到具体模块 |

~~内存布局复刻~~ 与 ~~调整 mss/wcnss 启动顺序~~ 已降级：
前者被 §3 补充证伪（同一布局既能崩也能不崩），后者在 §4b 实测里同序不崩。

实验 1–3 都可回滚：DTS 改完 `make dtb && make pack && fastboot boot` 内存试跑；
实验 4 必须在崩溃发生时立刻抓，晚了会被下次启动覆盖。
无论 1–4 结果如何，`modem-recover` 兜底都值得装：把最坏情况从"开机 3 分钟才可用"
压到约 10 秒，与根因是否解决无关。

## 8. 可用的对照组：ImmortalWrt r35810（6.12.45）

`F:\wifi\jz02\openwrt\jz02openwrt-sim.bin`，2026-11-09 刷入 JZ02，实测 **6 次冷启动全部干净**：

| 项 | 值 |
|---|---|
| 系统 | ImmortalWrt SNAPSHOT r35810-b08962bcb7，hostname 默认 `ImmortalWrt` |
| 内核 | 6.12.45（对比：出问题的 Debian 是 6.17.0-rc6） |
| 登录 | `root` / `admin`（LuCI 与 SSH 均可用） |
| 基带固件 | `mba.mbn 68468db5…` / `modem.mdt 4b4dc194…` —— **与 jz02v10 真机备份完全一致** |
| 设备树 | reserved-memory 与 jz02-firmware 的 6.17 DTB **逐条一致**（mpss `0x5500000`） |
| 启动顺序 | wcnss 10.3s → mss 20.1s（**与安卓相反**） |
| 结果 | 6/6 干净：mss `is now up` 各 1 次、`fatal error`/`dog.c`/`handling crash` 各 0 次；modem 连上 LTE/CMCC |

统计方法：每次冷启动后等 `uptime > 85s`（= mss up 之后 > 40s，覆盖完整看门狗窗口）再采样，
判据为 `4080000.remoteproc is now up` 出现次数 >1 或出现 crash 关键字。
注意 `reboot` 要十几秒才真正生效，判定"已重启"必须看 uptime 归零，
只看 SSH 是否断开会误判（首版脚本就栽在这里，5 轮里只真重启了 1 轮）。

结论：同硬件、同固件、同设备树，**只有内核不同**，而结果从"约半数开机崩"变成"6/6 干净"。
6.17 侧的内核改动是当前最强嫌疑。

## 9. 三固件交叉对照（2026-11-10 实测）

同一台 JZ02，同一套基带固件，只换固件/内核，各跑 6 次冷启动：

| 固件 | 内核 | 冷启动崩溃 | 备注 |
|---|---|---|---|
| ImmortalWrt r35810（第三方） | 6.12.45 | **0/6** | mss up 各 1 次 |
| 自编译（本仓 CI，r0-89f1ef1） | **7.3.1** | **6/6** | 每次 1~2 次崩溃，最终都能恢复 |
| Debian（jz02-firmware 基线） | 6.17.0-rc6 | 约 1/2 | 见 `baseband-boot-stall.md` |

自编译固件实测到的**两种崩溃签名**（同一台机器、同一份 MPSS）：

```
# 签名 A：up 之后约 5s
[15.720] qcom-q6v5-mss 4080000.remoteproc: fatal error received: smd_dsm_memcpy.c:297:
[15.720] remoteproc remoteproc0: crash detected ... type fatal error

# 签名 B：up 之后约 40s（与 Debian 侧一致）
[50.779] qcom-q6v5-mss 4080000.remoteproc: fatal error received: dog.c:1498:
```

6 次采样里有 3 次是"签名 A 再叠一次签名 B"（mss 起来 3 次才稳定）。

### 新的相关性：不是"顺序"，是"间隔"

| 固件 | wcnss up | mss up | 间隔 | 结果 |
|---|---|---|---|---|
| r35810 | 10.3s | 20.1s | **9.8s** | 干净 |
| 自编译 7.3.1 | 8.1s | 11.2s | **3.1s** | 崩 |
| 安卓（downstream） | 11.3s | 6.8s | -4.5s（modem 先） | 干净 |

§4b 里"顺序反了"的假设因此修正为：**wcnss 刚起就立刻拉 mss** 才是可疑点——
两个固件都是 wcnss 先，唯一区别是隔了 10 秒还是 3 秒；安卓干脆让 modem 先起。
签名 A 崩在 `smd_dsm_memcpy`（SMD 数据搬运），也符合"wcnss 尚未稳定就抢共享资源"。

验证方法（不动内核、只改用户态）：在 `/etc/init.d/rmtfs` 的 `start_service()` 里插
`sleep 8`，让 mss 在 wcnss 之后约 10s 才启动，再跑 6 次冷启动比崩溃率。

### 延时实验结果：签名 A 被消掉，签名 B 不受影响

7.3.1 固件上，打补丁前后各跑 6 次冷启动（打补丁前那一轮的开机不计入）：

| 组 | 签名 A（`smd_dsm_memcpy`, up+5s） | 签名 B（`dog.c:1498`, up+40s） | 判为崩溃 |
|---|---|---|---|
| 无延时 | **4/5** | 3/5 | 5/5 |
| `sleep 8` | **0/5** | 3/5 | 3/5 |

结论分成两条，性质不同：

- **签名 A 是用户态时序问题**：wcnss 刚起来就拉 mss，8 秒缓冲即可完全消除（0/5）。
  这一条不需要动内核，属于可以立刻落地的改进。
- **签名 B 是内核/固件层面的问题**：延时完全无效，仍是 3/5；而 6.12.45 内核 0/6 干净，
  6.17.0-rc6 与 7.3.1 都会出现 → 指向 6.12 之后的内核回归。

现场补丁位置：`/etc/init.d/rmtfs` 的 `start_service()` 首行 `sleep 8`，
原文件备份为 `/etc/init.d/rmtfs.orig`（`mv` 回去即可回滚）。

## 10. 6.12 交叉验证（2026-11-10 晚）—— 确定是内核版本

### 怎么搭起来的

用 OpenWrt 7.3.1 的 `.config` + `olddefconfig` 编 `msm8916-mainline/linux` 的
`msm8916/6.12` 分支（fc8cf0132），打包成 boot.img（cmdline 沿用 `rootfstype=squashfs`），
刷进 p12。踩了两个坑：

1. **模块放在 overlay 里，preinit 阶段看不见**：`/lib/modules/6.12.x` 被装到 overlay，
   而 kmodloader 在 overlay 挂载之前就读取，只能看到 squashfs 里的 7.3.1。
   结果 `USB_F_FS` / `USB_F_RNDIS` / `USB_LIBCOMPOSITE` 这些模块拿不到 → USB 复合设备
   根本不枚举 → 没有 RNDIS / adb / SSH，看起来像死机。
   解法：把 USB 复合功能、`QCOM_Q6V5_MSS`、`QCOM_WCNSS_PIL`、`SCM/SMEM/SMP2P` 全部改成
   `=y` 内置。
2. **6.12 不会自动启动 wcnss**：`a204000.remoteproc` 一直是 `offline`，而 7.3.1 会自动拉起。
   为对齐变量，加了一个实验脚本 `/etc/init.d/wcnss-pre`（`START=79`，手工 `echo start`），
   让 wcnss 在 rmtfs(S80) 之前起来。

### 结果

| 配置 | 内核 | wcnss | mss up 时刻 | 冷启动崩溃 |
|---|---|---|---|---|
| r35810（第三方） | 6.12.45 | 自动 | 20.1 s | **0/6** |
| 自编译固件 | 7.3.1 | 自动 | 11.2 s | **6/6** |
| 自编译 + `sleep 8` | 7.3.1 | 自动 | ~19 s | A 0/5、B 3/5 |
| 本次 6.12 | 6.12.0 | 未启动 | 21.6 s | **0/6** |
| 本次 6.12 + 手工拉 wcnss | 6.12.0 | S79 预启（4/6 轮确实起了） | ~21 s | **0/6** |
| 本次 6.15（`wip/msm8916/6.15`） | 6.15.0 | S79 预启 | ~21 s | **0/6** |
| 本次 6.18（`wip/msm8916/6.18-rc6`） | 6.18.0-rc6 | S79 预启（4/6 轮起了） | ~21 s | **0/6** |

6.12 = 0/6、7.3.1 = 6/6，Fisher 精确检验 **p ≈ 0.002**。把 wcnss 补回来之后依然是 0/6，
说明：

- **签名 B（`dog.c` 40 s 停滞）由内核版本决定**，跟 wcnss 竞争无关；
- **签名 A（`smd_dsm_memcpy`，up+5 s）由 wcnss→mss 的间隔决定**，加 8 s 缓冲即可消除。

### 二分结果：回归在 6.18 之后

| 内核 | 冷启动崩溃 |
|---|---|
| 6.12.0 / 6.15.0 / 6.18.0-rc6 | 0/6、0/6、0/6 |
| 7.3.1（构建所用） | 6/6 |

即回归发生在 **6.18 → 7.3** 之间（6.19 / 7.0 / 7.1 / 7.2 / 7.3 里）。6.13 已编好待用
（`~/build/linux-6.13`，`6.13.0-rc7`），本轮因 6.15 已干净而未测。

> 测试方法补充：USB RNDIS 偶发被 Windows 置为 Disabled 导致 SSH 中断，改用 `adb shell`
> 探活/重启后稳定（`~/work/bootcamp_adb.py`）。

### 落地：云编译已切到 6.18

`build.sh` 新增 `KERNEL_PATCHVER`（默认 `6.18`），在复制 target 之后覆写
`openwrt/target/linux/msm89xx/Makefile` 里的 `KERNEL_PATCHVER:=7.3`。target 自带
`config-6.18` / `patches-6.18`（6 个补丁），无需额外移植。

### 后续可选

若要把回归点钉到具体提交：在 6.18 → 7.3 之间二分（`wip/msm8916/6.19`、`7.0`、`7.1`、
`7.2`、`7.3` 分支都在），每档编 3~5 分钟 + 6 次冷启动。判据仍是 `fatal error received: dog.c`。

### 遗留的不严谨处

本次几个测试内核都是"精简内置"配置（`USB_*` / `q6v5` 内置；`QCOM_BAM_DMUX` 因
`DMA_ENGINE` 依赖仍是模块而未加载），与 7.3.1 的模块加载面不完全一致。
不过 6.12 / 6.15 / 6.18 三档一致、7.3.1 独崩，方向性结论不受影响；
彻底闭环可把模块打进 squashfs 后复测。

### ⚠ 修正（2026-11-11 凌晨）：完整固件上 6.18 仍崩 A，但不再崩 B

用 CI 正式构建（`KERNEL_PATCHVER=6.18` → 内核 **6.18.55**，带 `kmod-bam-dmux`
等完整模块）刷机实测，**6 次冷启动全部崩**：

| 轮次 | mss up | A `smd_dsm_memcpy` | B `dog.c` |
|---|---|---|---|
| 1–6 | 各 2 次 | 5/6 | **0/6** |

即：**6.18 消除了签名 B（40 s 停滞），但签名 A 依然存在**（up 之后 3~5 s，重启即恢复）。

这也说明前面"6.12/6.15/6.18 测试内核 0/6 干净"的结论**只对签名 B 成立**：
那批内核没有加载 `qcom_bam_dmux`（模块没打进 squashfs），SMD 数据通道不存在，
签名 A 自然不会发生。**A 的触发依赖 bam-dmux 加载**，与内核版本关系待定。

数据面在 6.18.55 上是通的：`wwan0 10.12.15.21`、`mmcli` 显示 LTE / CHINA MOBILE / 67%。

## 11. 最终结论（2026-11-11 02:00）：A 是用户态脚本抢跑，B 才是内核

### 决定性实验（都在 6.18.55 同一份固件上）

| 条件 | 冷启动结果 |
|---|---|
| 原样 | **6/6 崩 A** |
| rmtfs 加 `sleep 12`（推迟起 mss） | 6/6 崩 A（无效） |
| **禁用全部 JZ02 用户态脚本**（qmi-modem-410-init / qmi_auto_activate / auto_apn / smsrelay） | **5/5 干净** |
| 只给两个 QMI 脚本加"等 wwan0 就绪"，auto_apn / smsrelay 保持启用 | **0/6 干净** |

结论明确：触发源是 **`qmi-modem-410-init`（S99，DELAY=0）和 `qmi_auto_activate`（S98，带 respawn）**
——它们在 modem 初始化窗口内就发 QMI，modem 侧报
`fatal error received: smd_dsm_memcpy.c:297` 并重启。`auto_apn` / `smsrelay` 不是触发源。

### 两条签名分别归因

| 签名 | 现象 | 根因 | 处理 |
|---|---|---|---|
| **A** | up 后 3~5 s，`smd_dsm_memcpy.c:297` | **用户态脚本抢跑**：QMI 请求落在 modem 初始化窗口内。凡是带这套 JZ02 脚本的固件都有（7.3.1 / 6.18 都是） | 等 `wwan0` 出现再发 QMI（已实现，见下） |
| **B** | up 后 40 s，`dog.c:1498` 停滞 | **内核回归**：6.18 无、6.17 与 7.3.1 有 | 内核固定 6.18 |

### 为什么之前一路误判成内核问题

1. 手编的测试内核（6.12/6.15/6.18）**没带 `qcom_bam_dmux`**（模块没打进 squashfs）→
   没有 SMD 数据通道 → QMI 脚本根本连不上 modem → 0/6 干净，是**假阴性**。
2. r35810（6.12.45）干净，是因为它是**通用 ImmortalWrt，没有这套 JZ02 脚本**。
3. 于是"6.18 干净 / 7.3.1 崩"被误读成内核回归——其实只有 B 是。

### 落地（已进仓库）

| 位置 | 改动 |
|---|---|
| `build.sh` | `KERNEL_PATCHVER=${KERNEL_PATCHVER:-6.18}`，覆写 target 的 `7.3`；6.18 下移出 `0104-uapi-128bit.patch`（已合入上游，否则 toolchain/kernel-headers 编译失败） |
| `files/usr/bin/wait-modem` | 等 `wwan0` 出现 + 5 s 稳定期 |
| `files/etc/init.d/qmi-modem-410-init` | 改为 `wait-modem; exec qmi-modem-410-init` |
| `files/etc/init.d/qmi_auto_activate` | 同上（保留 respawn） |

实测：**6.18.55 + 上述修复 = 0/6 崩**，且 `wwan0 10.36.76.167`、`mmcli` connected/LTE/CMCC 75%，
smsrelay 正常运行——功能面未受影响。

## 12. 复核（2026-11-11 08:30）：修复与内核无关，但 B 确实是内核回归

按"若与内核无关就保持最新内核"的设想，用**同一套修复**在 **7.3.1** 上重新出包验证：

| 内核 | QMI 修复 | 冷启动结果 |
|---|---|---|
| 7.3.1 | 有 | **A 0/6**（`fatal error` 里一次 `smd_dsm_memcpy` 都没有） |
| 6.18.55 | 有 | A 0/6 |

→ **A 与内核版本无关，修复在 7.3.1 上同样有效。**

但 B 在 7.3.1 上依然存在，而且表现为"轻症常态化"：

| 轮次（7.3.1） | mss `is now up` | `dog.c` | modem-recover 主动重启 | mss → `wwan0qmi0` |
|---|---|---|---|---|
| 1（擦 overlay 首启） | 5 | **1**（147 s） | 3 次全失败 | **117 s** |
| 2 | 2 | 0 | 1 次 | 24.9 s |
| 3 | 4 | 0 | 3 次 | 95 s 时端口仍未出现 |
| 4 | 4 | 0 | 3 次 | 95 s 时端口仍未出现 |
| 5 | 2 | 0 | 1 次 | 24.9 s |
| 6 | 2 | 0 | 1 次 | 24.8 s |

同一块板、同一套修复，6.18 是 **6/6 都在 1.2~3.8 s 出端口、`modem-recover` 一次没触发**；
7.3.1 是 **6/6 都要靠主动重启 mss 才出端口**，还有 1/6 走到 `dog.c:1498` 停滞、117 s 才恢复。

结论：**A = 用户态，B = 内核**，两者彻底分离。因此内核仍固定 6.18，
`modem-recover` 保留为 6.18 上的兜底（在 6.18 上实测不触发，仅在回归内核上才会动作），
等待阈值从 12 s 放宽到 20 s（12 s 会把"正常但慢"的 16.9 s 启动误判成停滞）。

### 最终交付版本的复核（6.18.55 + 全部修复）

擦掉 overlay 重刷后，6 次冷启动：

| 轮次 | mss `is now up` | `fatal error` | `dog.c` | recover 触发 | mss → wwan0 |
|---|---|---|---|---|---|
| 1–6 | 每轮 **1** 次 | 0 | 0 | **0** | 1.2 s（1 轮 1.2 s，其余 1.2 s） |
| 汇总 | — | — | — | — | **0/6 崩溃** |

功能面：`mmcli` connected / LTE / CHINA MOBILE / 75% / attached，默认路由 `via wwan0`，
`smsrelay` + `smsrelay-keepalive` 在跑，`qmi-proxy` 正常，overlay f2fs 3.1 G。
（`qmi_auto_activate` 由 `files/etc/uci-defaults/99-jz02-local` 有意禁用，拨号由
`qmi-modem-410-init` + `auto_apn` 完成，属既定设计。）

### 脚本复核（2026-11-11 09:10）：两处逻辑缺陷已修

| 问题 | 原状 | 现在 |
|---|---|---|
| **`wait-modem` 超时保护失效** | 调用方写 `/usr/bin/wait-modem; exec qmi-modem-410-init`，**分号**意味着一律继续，等不到 `wwan0` 也照发 QMI——正好绕过修复本意 | 改 `&&`；`qmi-modem-410-init` 用 `for i in 1 2 3` 重试（每次 60 s），三轮都超时则只记日志、**不发 QMI**。该脚本是一次性任务，**刻意不加 respawn**（否则会反复重生、反复发 QMI） |
| **`modem-recover -n 3` 是纯消耗** | 真 stalled 时实测重启 3 次**全部无效**（重启后照样停滞），白花 72 s，最后还是靠 dog 40 s 自愈 | 改 `-n 1`：试一次，不成就交给内核看门狗 |

另外 `build.sh` 的 0104 补丁分支补上了**反向恢复**（切回 7.3 等低版本时把
`.disabled` 挪回 `patches/`），避免"切过 6.18 再切回来缺补丁"。

改后重新出包、擦 overlay 重刷，6 次冷启动仍 **0/6 崩**（mss 每轮 1 次、gap 1.2 s、recover 0），
数据面 `attached` + 默认路由 `via wwan0`，说明 QMI 初始化路径未被改坏。



