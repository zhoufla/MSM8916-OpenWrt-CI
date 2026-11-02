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
- **CPU**：schedutil + 默认 800MHz 上限，LuCI 页可调
- **IPv6**：WAN 侧 DHCPv6（DDNS 用），LAN 不分发
- **凭据不进仓库**：无线 SSID/密码、root 密码均为构建期注入（环境变量 / GitHub Secrets）；
  未提供则生成未配置固件（设备靠 LTE/USB 管理）

## 机型

| MODEL | 设备 | 上游设备定义 | 设备树 | 真机验证 |
|---|---|---|---|---|
| `jz02v10` | Zhihe jz02-v10 4G Modem Stick | `openstick-jz02v10` | `msm8916-thwc-jz02v10` | 是 |
| `sp970v11` | GeXing SP970-V11 4G Modem Stick | `openstick-sp970v11` | `msm8916-gexing-sp970` | 否 |

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
jz02/wireless.tpl          # 无线配置模板（占位符）
scripts/gen-wireless.sh    # 模板渲染（CI 与本地共用）
scripts/pull-modemfw.sh    # 基带真机提取（ssh → firmware/，md5 校验）
scripts/fat_extract.py     # 原厂 modem 分区 FAT 镜像抽取工具
scripts/sync-modemfw.sh    # 基带同步（qcom-firmware → firmware/）
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
加载基带、启动 Hexagon 调制解调器核；`rmtfs` 用设备上原厂 `modemst1/modemst2` 分区
提供 EFS/NV 存储。刷机/升级只写 boot/rootfs 分区，基带与 NV 始终保持出厂状态。
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

## 已知坑（build.sh 已内置处理）

1. **gc 包校验和**：openstick feeds 的 `PKG_MIRROR_HASH` 对构建机 git 版本敏感 → `skip`
2. **firewall4 fullcone 补丁**：仅上游 pin 在旧 commit 时适用 → 按版本判断
3. **mkbootimg**：生成 boot.img 必需，runner 默认没有 → deb 解包到 `~/.local/bin`
4. **内核并行竞态**：`-j$(nproc)` 偶发 `fixdep` 失败 → 整体失败后单线程重编内核续跑

## 相关仓库

- [xuxin1955/Actions](https://github.com/xuxin1955/Actions) — msm89xx target 本体与 files-8916
- [zhoufla/SMSRelay8916](https://github.com/zhoufla/SMSRelay8916)（`openwrt` 分支）— 短信网关
- [lkiuyu/qcom-firmware](https://github.com/lkiuyu/qcom-firmware) — 各机型原厂 modem 分区 dump（内置基带的来源）
