# MSM8916-OpenWrt-CI

[jz02v10](https://github.com/xuxin1955/Actions)（Zhihe jz02-v10 4G Modem Stick，MSM8916）的
ImmortalWrt 云编译与本地构建脚本，基于 openstick 移植生态。

特性（相对上游 openstick 镜像的定制，全部经真机验证）：

- **精简**：剔除 docker/istore/simadmin 等无关包（423 → 357 CONFIG），system.img 约 43MB
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

## 云编译

1. 在仓库 **Settings → Secrets and variables → Actions** 添加（全部可选）：

   | Secret | 用途 |
   |---|---|
   | `WIFI_SSID` / `WIFI_PSK` | 烧进固件的无线 STA 凭据；不设则未配置 |
   | `ROOT_PASSWORD` | 设备 root 密码（构建时生成哈希，仓库不落明文/哈希） |
   | `LAN_IP` | LAN 地址，默认 `192.168.1.1` |

2. **Actions → Build jz02v10 → Run workflow**（勾选 release 可同时发版）；
   也可直接打 `v*` tag 触发；每周六自动跟一次上游。

产物：`boot.img`（fastboot 刷 boot 分区）+ `system.img`（rootfs）+ `sysupgrade.bin`。
注意分区表需含 `rootfs_data`（f2fs overlay）——从原厂分区迁移的方法见 jz02v10 相关文档。

## 本地构建

```bash
./build.sh                       # 完整构建（约 40-90 分钟，12 核参考）
WIFI_SSID=MyHome WIFI_PSK=xxx ./build.sh
SKIP_SMSRELAY=1 ./build.sh       # 只编固件不编短信网关
```

依赖（Ubuntu 22.04/24.04 与 WSL 实测）：

```bash
sudo apt-get install build-essential clang flex bison g++ gawk gettext git \
  libncurses-dev libssl-dev rsync unzip zlib1g-dev file wget curl ccache cmake \
  cpio python3 python3-pip swig bc time xxd libelf-dev
# Go 1.26+（仅编译 SMSRelay 需要；SKIP_SMSRELAY=1 可免）
```

## 目录

```
build.sh                   # 全流程：拉源码 → 应用 target → 补丁 → files → 编译
configs/feeds.conf         # feeds 固定 commit
configs/jz02v10.diffconfig # 设备 .config（精简版）
files/                     # 根文件系统覆盖层（服务、LuCI、uci-defaults）
jz02/wireless.tpl          # 无线配置模板（占位符）
scripts/gen-wireless.sh    # 模板渲染（CI 与本地共用）
.github/workflows/         # Actions 工作流
```

## 已知坑（build.sh 已内置处理）

1. **gc 包校验和**：openstick feeds 的 `PKG_MIRROR_HASH` 对构建机 git 版本敏感 → `skip`
2. **firewall4 fullcone 补丁**：仅上游 pin 在旧 commit 时适用 → 按版本判断
3. **mkbootimg**：生成 boot.img 必需，runner 默认没有 → deb 解包到 `~/.local/bin`
4. **内核并行竞态**：`-j$(nproc)` 偶发 `fixdep` 失败 → 整体失败后单线程重编内核续跑

## 相关仓库

- [xuxin1955/Actions](https://github.com/xuxin1955/Actions) — msm89xx target 本体与 files-8916
- [zhoufla/SMSRelay8916](https://github.com/zhoufla/SMSRelay8916)（`openwrt` 分支）— 短信网关
