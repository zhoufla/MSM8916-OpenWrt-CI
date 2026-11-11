# MSM8916-OpenWrt-CI

[jz02v10 / sp970v11](https://github.com/xuxin1955/Actions)（Zhihe jz02-v10、GeXing
SP970-V11，均为 MSM8916 4G Modem Stick）的 ImmortalWrt 云编译与本地构建脚本，基于
openstick 移植生态。

特性（相对上游 openstick 镜像的定制；jz02v10 经真机验证，sp970v11 见「机型」表）：

- **精简**：剔除 docker/istore/simadmin 等无关包；短信网关定位下再裁 USB 存储/网卡
  变体、iptables 兼容栈、sqlite3/curl/xz 等无关工具库（diffconfig 显式选包 144 → 64，
  展开数以实际构建为准）
- **基带内置**：jz02v10 / sp970v11 原厂基带（MBA+MPSS，24 文件/机型）**从真机提取**
  后随仓库分发，构建期解压到 `/lib/firmware`；本地缺失的机型自动回退远程 openstick
  feed（见「基带固件」）
- **短信网关**：内置 [SMSRelay](https://github.com/zhoufla/SMSRelay8916)（收发、验证码提取、
  多通道转发），procd 双实例托管，LuCI「服务 → 短信网关」嵌入其自带 UI
- **LTE 保活**：MPSS（2015）在 LTE 空闲态收不到寻呼会导致短信延迟，keepalive 实例周期保活
  并在断网时 `ifdown/ifup modem` 自愈（netifd 版）
- **USB 自愈**：Windows 对 RNDIS 选择性挂起导致数据面卡死时自动重绑 UDC
- **LED**：只保留电源灯；SIM 卡槽 GPIO 不受影响
- **SIM 卡槽自愈（sp970v11）**：SP970 的 `sim:sel` 是实体卡/eSIM 切换线而非 LED。
  开机被 USB 触发器带跑时会停在 eSIM 一侧，叠加厂商 `activate_sim` 被注释，
  表现为 `sim-missing` 且 LTE 起不来。`simfix`（S99）按板型门控介入，
  jz02v10 一根 GPIO 都不碰（见「SIM 卡槽」）
- **CPU**：schedutil + 默认 800MHz 上限，LuCI 页可调
- **IPv6**：WAN 侧 DHCPv6（DDNS 用），LAN 不分发
- **无线自动连接**：`wifi-preload`（S19）在 network 之前等 `phy0`，`wifiwan-ensure`（S95）
  在接口真没起来时补一次 `ifup`。msm8916 的 modem/wcnss/wcn36xx 都是模块，`phy0` 要 10s
  才注册，netifd 在 S20 抢跑会留下 `NO_DEVICE` 且不重试（表现：无线已关联、`wifiwan`
  无 IPv4）；正常启动两个服务只在日志各留一行 `ok`
- **凭据不进仓库**：无线 SSID/密码、root 密码均为构建期注入（环境变量 / GitHub Secrets）；
  未提供则生成未配置固件（设备靠 LTE/USB 管理）

## 机型

| MODEL | 设备 | 上游设备定义 | 设备树 | 真机验证 |
|---|---|---|---|---|
| `jz02v10` | Zhihe jz02-v10 4G Modem Stick | `openstick-jz02v10` | `msm8916-thwc-jz02v10` | 是 |
| `sp970v11` | GeXing SP970-V11 4G Modem Stick | `openstick-sp970v11` | `msm8916-gexing-sp970` | 是（2026-11-02） |

- 机型经 `MODEL` 环境变量 / workflow 输入选择，配置在 `configs/<model>.diffconfig`；
  build.sh 内有 MODEL → 设备树 的映射表，新机型在这里加一行。
- 两者共用 files 覆盖层（短信网关、LTE 保活、USB 自愈、CPU 调速等）；jz02 的 LED
  策略脚本对 LED 名做了存在性保护，SP970-V11 的实际效果仍需真机确认。

## 云编译

1. 在仓库 **Settings → Secrets and variables → Actions** 添加（全部可选）：

   | Secret | 用途 |
   |---|---|
   | `WIFI_SSID` / `WIFI_PSK` | 烧进固件的无线 STA 凭据；不设则未配置 |
   | `ROOT_PASSWORD` | 设备 root 密码（构建时生成哈希，仓库不落明文/哈希） |
   | `LAN_IP` | LAN 地址，默认 `192.168.1.1` |

2. **Actions → Build msm8916 → Run workflow**（默认 `both`：两个机型 matrix 并行编译，
   也可单独选择某个机型；勾选 release 可同时发版）；也可直接打 `v*` tag 触发；
   每周六自动跟一次上游（两个机型一起编译）。
   Release 为独立 job 汇总：两机型产物合并发一次版，校验和按机型命名为
   `sha256sums-<model>.txt`。

产物：`boot.img`（fastboot 刷 boot 分区）+ `system.img`（rootfs）+ `sysupgrade.bin`。
注意分区表需含 `rootfs_data`（f2fs overlay）——从原厂分区迁移的方法见 jz02v10 相关文档。

## 本地构建

```bash
./build.sh                       # 完整构建（约 40-90 分钟，12 核参考）
MODEL=sp970v11 ./build.sh        # 指定机型（默认 jz02v10）
WIFI_SSID=MyHome WIFI_PSK=xxx ./build.sh
SKIP_SMSRELAY=1 ./build.sh       # 只编固件不编短信网关
```

依赖（Ubuntu 22.04/24.04 与 WSL 实测）：

```bash
sudo apt-get install build-essential clang flex bison g++ gawk gettext git \
  libncurses-dev libssl-dev rsync unzip zlib1g-dev file wget curl ccache cmake \
  cpio python3 python3-pip swig bc time xxd libelf-dev xz-utils
# Go 无需单独安装：smsrelay 是标准构建树包（package/smsrelay），
# 由构建树拉取源码、用自带 golang 工具链编译并产出 ipk
```

## 目录

```
build.sh                   # 全流程：拉源码 → 应用 target → 补丁 → files → 编译
configs/feeds.conf         # feeds 固定 commit
configs/jz02v10.diffconfig  # jz02v10 设备 .config（精简版）
configs/sp970v11.diffconfig # sp970v11 设备 .config（精简版）
files/                     # 根文件系统覆盖层（服务、LuCI、uci-defaults）
firmware/                  # 项目内置基带（firmware/<model>/*.xz）
firmware/<model>/nv/       # 设备专属 EFS/NV 备份（modemst1/2，短信 CS 域必需）
jz02/wireless.tpl          # 无线配置模板（占位符）
scripts/gen-wireless.sh    # 模板渲染（CI 与本地共用）
scripts/test-simfix.sh     # simfix 离线验证（板型门控，无需真机）
scripts/pull-modemfw.sh    # 基带真机提取（ssh → firmware/，md5 校验）
scripts/fat_extract.py     # 原厂 modem 分区 FAT 镜像抽取工具
scripts/sync-modemfw.sh    # 基带同步（qcom-firmware → firmware/）
scripts/nv.sh              # NV 回读 / 刷入 / CS 域检查（fastboot + adb）
.github/workflows/         # Actions 工作流
```

## 基带固件（modem）

OpenWrt 只构建内核和 rootfs；MSM8916 的基带（MBA + MPSS）是高通闭源固件，来自设备
原厂系统。本项目内置的基带**直接从真机提取**（`/lib/firmware/mba.mbn` + `modem.*`，
24 个文件/机型，xz 压缩）放在 `firmware/<model>/`；社区 dump
（[lkiuyu/qcom-firmware](https://github.com/lkiuyu/qcom-firmware)）仅作参考来源——
实测 sp970v11 真机与社区 dump 有 4 个文件不同（`modem.mdt`、`modem.b01/b20/b21`），
以真机为准。build.sh 第 7 步的处理逻辑：

1. `firmware/<MODEL>/` 存在 → 解压到 rootfs 的 `files/lib/firmware/`，并从
   `DEVICE_PACKAGES` 摘掉远程 `qcom-msm8916-modem-openstick-<model>-firmware` 包，
   构建不再依赖远程仓库；
2. 本地没有对应机型 → 保持上游行为，构建期由 openstick feed 远程拉取同名固件包。

运行时由内核 `qcom,msm8916-mss-pil`（kmod-qcom-rproc-modem）经 PIL 从 `/lib/firmware`
加载基带、启动 Hexagon 调制解调器核；`rmtfs` 用设备上 `modemst1/modemst2` 分区
提供 EFS/NV 存储。**常规刷机（`fastboot flash boot/rootfs`）不碰这两个分区**，
但整盘恢复（EDL / MiKo 写全盘镜像）会覆盖它们——NV 里含短信所需的 CS 域设置，
覆盖后需要补刷，见下节。
WiFi/BT 固件（`wcnss.*`）与校准 NV 未内置，仍来自上游 feed 包。

### 从真机提取基带（推荐）

```sh
FW_PASS=<设备root密码> ./scripts/pull-modemfw.sh <model> <设备地址>
# 例: FW_PASS=xxx ./scripts/pull-modemfw.sh jz02v10 192.168.1.1
```

设备需已运行 openstick / ImmortalWrt 且可 root 登录。脚本 tar over ssh 拉取
`/lib/firmware` 的基带文件，**逐文件 md5 与设备端校验一致后**才替换
`firmware/<model>/`；密码仅经环境变量传入，不落盘、不进仓库。需 ssh、tar、md5sum、xz。

### 从社区 dump 同步（补充）

```sh
./scripts/sync-modemfw.sh jz02v10 sp970v11   # 需 curl、python3、xz
```

脚本从固定 commit（`FW_COMMIT=xxx` 可覆盖）下载对应机型的
`openstick-<model>-modem.bin`（原厂 modem 分区镜像），用 `scripts/fat_extract.py`
抽取基带后 `xz -9` 入库，来源可复现。注意 dump 可能与真机有出入（见上），入库后
建议再用 `pull-modemfw.sh` 以真机覆盖。

## 基带 NV 与短信 CS 域

**现象**：能正常 4G 上网，但短信收发全废——`mmcli --send` 卡满 30 s 超时，
`AT+CMGS` 也拿不到 `+CMGS`；`inbox` 恒为 0。看 QMI 而非 AT 才能定位：

```sh
qmicli -d /dev/wwan0qmi0 --device-open-proxy --nas-get-serving-system
# 异常: CS: 'detached' / PS: 'attached'
qmicli -d /dev/wwan0qmi0 --device-open-proxy --nas-get-system-selection-preference
# 异常: Service domain preference: 'ps-only'  (正常应为 'cs-ps')
```

短信走 CS 域、上网走 PS 域。`ps-only` 时 CS 永远注册不上，与基带固件、SMSC、
短信存储、SIM 都无关（这些实测全正常）。这项偏好存在 **EFS/NV（`modemst1/2`）** 里，
原厂 `fsg` 与 `modem` 固件分区均无此设置；QPST 里勾「CS and PS」改的就是它。
本仓库 `firmware/<model>/nv/` 存的是真机实测可用的一份（`xz` 压缩，各约 900 KB）。

```sh
./scripts/nv.sh check                    # 看当前 CS/PS 注册状态与域偏好
./scripts/nv.sh pull  jz02v10           # 从 adb 设备回读 modemst1/2，md5 校验后压缩入库
adb reboot bootloader
./scripts/nv.sh flash jz02v10           # 解压并 fastboot 刷入
fastboot reboot
```

`flash` 需要设备已在 fastboot 模式；`pull` 走「设备内 dd → adb pull → 本地 md5 比对」，
避免 `adb shell dd` 经 PTY 把 `\n` 转成 `\r\n` 导致 dump 损坏。

> **设备专属数据**：`modemst` 含 IMEI 与射频校准，只适用于这台机器，不要跨机刷、
> 不要外传。常规 `fastboot flash boot/rootfs` 不会覆盖它；**整盘镜像恢复会**，
> 刷完全盘后必须补刷 `nv/`，再用 `check` 确认 `CS: 'attached'`。

## 已知坑（build.sh 已内置处理）

1. **gc 包校验和**：openstick feeds 的 `PKG_MIRROR_HASH` 对构建机 git 版本敏感 → `skip`
2. **firewall4 fullcone 补丁**：仅上游 pin 在旧 commit 时适用 → 按版本判断
3. **mkbootimg**：生成 boot.img 必需，runner 默认没有 → deb 解包到 `~/.local/bin`
4. **内核并行竞态**：`-j$(nproc)` 偶发 `fixdep` 失败 → 整体失败后单线程重编内核续跑
5. **STA 侧 WAN 启动竞态**：`phy0` 由 `qcom-q6v5-mss`/`qcom_wcnss_pil`/`wcn36xx` 这几个
   模块异步拉起，S20 时未必就绪，netifd 那次 `ifup` 会失败并留下 `NO_DEVICE`（不再重试），
   表现为"无线关联成功、`wifiwan` 没有 IPv4"。分两层处理：
   `wifi-preload`（S19，早于 `S20network`）等 `phy0` 出现再放行启动；
   `wifiwan-ensure`（S95）仅在接口仍未起来时补**一次** `ifup`，关联成功后先静默 12s
   让 netifd 自己收尾。**不要改成循环 ifup**：对无线接口反复 `ifup` 会触发
   wifi-scripts 重建 vif（`Remove interface phy0-sta0` + deauth），自己打断自己。
   排查：`logread -e wifi-preload` / `logread -e wifiwan-ensure`。
   另：`wifiwan6` 的 `device` 必须写 `@wifiwan`，不能写死 `phy0-sta0`（理由见
   `99-jz02-local` 注释）

## SIM 卡槽（sp970v11）

SP970 上 `/sys/class/leds/sim:sel` 名字像 LED，实际是**实体卡 / eSIM 切换线**：

| `sim:sel` 电平 | 实际卡 | 真机实测标识 |
|---|---|---|
| `0` | 实体卡槽（物理 SIM） | IMSI `46002…`，CMCC |
| `1` | 板载 eSIM | ICCID `898611…`，中国电信 |

刷机后出现 `sim-missing`、`mmcli -m 0` 长期 `failed`、netifd 每 10s 刷
"SIM missing"，是三层原因叠加：

1. 该线开机时被绑到 `usb-gadget` 触发器，电平随 USB 状态跑，经常停在 eSIM 一侧；
2. 厂商 `/usr/bin/qmi-modem-410-init` 里 `activate_sim` 的调用被注释掉，
   `repower_sim()` 首行直接 `return 0` —— 卡槽选对了 USIM 也停在 `detected`，
   进不到 `ready`，ModemManager 于是判 `failed / sim-missing`；
3. MPSS 开机后连续 watchdog 崩溃 3~5 次（开机 2~3 分钟才稳定），期间 `/dev/wwan*` 消失。

`files/etc/init.d/simfix`（S99）按这个顺序自愈：等 QMI 端口连续稳定 20s → 停
ModemManager（qmicli 与它抢端口会报 `endpoint hangup`）→ 解绑触发器并把 `sim:sel`
钉到 `slot` → 必要时重新上电 → 激活 provisioning session → 启回 MM、`--enable`、`ifup modem`。

配置 `/etc/config/simfix`（默认值即可用）：

| 选项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `1` | `0` 完全停用 |
| `slot` | `0` | `0` 实体卡 / `1` eSIM / `-1` 不干预 |
| `force` | `0` | `1` 允许非 `gexing,sp970` 的**单线**板子也执行 |
| `max_wait` / `stable_need` | `360` / `20` | 等端口稳定的上限与所需连续秒数 |
| `power_cycle` | `1` | 卡不在位时重新上电 |
| `tries` | `3` | 激活重试次数 |

### 对 jz02v10 的影响：无（双重门控）

两个机型共用 `files/` 覆盖层，门控只能写在脚本里、不能靠构建期区分：

| | jz02v10 | sp970v11 |
|---|---|---|
| DTS `leds` 节点 | `sim:sel`(tlmm 1, `default-state="on"`)、`sim:en`(20)、`sim:sel2`(22)、`sim:en2`(23) | 只有 `sim:sel`(tlmm 114, `"off"`) |
| `compatible` | `thwc,jz02v10` | `gexing,sp970` |
| simfix 行为 | **跳过**（日志 `is not gexing-sp970, skip`），不停 MM、不写任何 GPIO | 接管 |

1. **compatible 门控**：`/proc/device-tree/compatible` 不含 `gexing,sp970` 直接 `return 0`；
2. **四线拓扑硬门控**：`sim:en2` / `sim:sel2` 任一存在即拒绝，**即使 `force=1` 也不接管**
   —— jz02 卡槽映射完全不同，`sim:sel` 默认还是 `on`，拉 0 会把在用卡切走。

`files/etc/rc.d/S99simfix` 是随镜像下发的软链（保证首次开机就生效，不依赖
uci-defaults 的时序）；jz02 上它同样会被启动，但脚本在 `start()` 里就返回，只留一行日志。
sysupgrade 保留见 `files/etc/sysupgrade.conf`。

### 本地验证（不需要真机）

```sh
./scripts/test-simfix.sh
```

用假的 sysfs / device-tree / qmicli / mmcli / uci 跑真实脚本，断言：sp970 会钉卡槽并完成激活、
jz02 与 jz02+`force=1` 一根 GPIO 都不碰、`enabled=0` 完全不动。

## 相关仓库

- [xuxin1955/Actions](https://github.com/xuxin1955/Actions) — msm89xx target 本体与 files-8916
- [zhoufla/SMSRelay8916](https://github.com/zhoufla/SMSRelay8916)（`openwrt` 分支）— 短信网关
- [lkiuyu/qcom-firmware](https://github.com/lkiuyu/qcom-firmware) — 各机型原厂 modem 分区 dump（内置基带的来源）
