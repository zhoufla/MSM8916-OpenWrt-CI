# 基带崩溃：现场复核 + 文档之外的新方案

复核时间：2026-11-03　设备：JZ02（thwc,jz02v10）/ SP970（gexing,sp970）
系统：ImmortalWrt SNAPSHOT / Linux 7.3.1 aarch64 / target msm89xx-msm8916
原始结论文档：`baseband-boot-stall.md`（本文是它的后续：同样的现象，但结论有修正）

---

## 一、现场实测时间线（比文档记录更细，且比文档记录更差）

### 216 / JZ02（本次开机）

| 事件 | 时间 | 备注 |
|---|---|---|
| MBA booted，开始加载 mpss | 13.18s | |
| `is now up`（首次） | 23.69s | 首次加载耗时 **10.51s** |
| `failed to announce new service` | 23.693s | 距 up **+0.7ms** |
| `failed while handling packet from 0:-2` | 23.699s | |
| crash #1（dog.c:1498） | 63.74s | up + 40.05s |
| 重试 → up | 64.50s | 重试加载耗时 **0.58s** |
| crash #2 / #3 / #4 | 104.55 / 145.36 / 186.15 | 均 up + 40.05s |
| up（第 5 次） | 186.88s | **这一次没有 fail-announce** |
| wwan0at0/at1/qmi0 attached | 187.47 / 187.47 / 187.66 | 成功者 1s 内出端口 |

开机到基带可用：**187s**，代价 4 × 40s 空等。

### 143 / SP970（本次开机）

| 事件 | 时间 | 备注 |
|---|---|---|
| `is now up`（首次） | 18.82s | 首次加载 **5.91s** |
| crash #1（**smd_dsm_memcpy.c:297**） | 22.54s | up + 3.72s，**不是看门狗**，且无 fail-announce |
| up（第 2 次） | 23.20s | +fail-announce |
| crash #2（dog） | 63.25s | |
| up（第 3 次） | 64.04s | +fail-announce |
| crash #3（dog） | 104.09s | |
| up（第 4 次） | 104.85s | **无 fail-announce** → 成功 |
| `bam-dmux: Channel already open: 0..7` | 105.47s | 见 2.3 |

开机到基带可用：**105s**，崩溃 3 次（文档记的是"23s 崩 1 次自愈"，实测更差）。

---

## 二、文档里没有的四条事实

### 2.1 ★ `failed to announce new service` 与 dog.c 卡死 100% 共现

把每次 `is now up` 与 crash 一一对齐：

| 设备 | 启动序 | 出现 fail-announce | 结果 |
|---|---|---|---|
| 216 | 1 | 是 | 崩 |
| 216 | 2 | 是 | 崩 |
| 216 | 3 | 是 | 崩 |
| 216 | 4 | 是 | 崩 |
| 216 | 5 | **否** | **成** |
| 143 | 2 | 是 | 崩 |
| 143 | 3 | 是 | 崩 |
| 143 | 4 | **否** | **成** |

8/8 完全一致：**握手脏的启动全崩，握手干净的启动全成**（143 的第 1 次是另一种崩溃 `smd_dsm_memcpy`，发生在 fail-announce 之前，属另一条路径）。

关键点在时序上：
```
[23.692594] ... remote processor 4080000.remoteproc is now up
[23.693313] failed to announce new service        ← +0.7ms
[23.699342] failed while handling packet from 0:-2
[63.739197] fatal error received: dog.c:1498:     ← 之后 40s 完全静默
```
主机侧的错误发生在 up 之后 **1ms 内**，远早于看门狗的 40s 死等。也就是说：

> modem 并没有"从第一刻就零进展"——它已经跑到了 SMD 服务宣告这一步，是**主机的 rpmsg/SMD 名称服务没能把这次宣告处理掉**，之后 modem 等不到回应才被自家看门狗打死。

这两行来自主机的 rpmsg/SMD 名称服务路径（不是用户态打印），所以原文档"主机侧任何用户态进程都不可能是阻塞者"的推论需要修正：用户态进程确实不是阻塞者，但**内核对 modem 首个名称服务包的处理失败**是。

至于 `from 0:-2`：第二个字段是负值，说明解析出的 SMD 命令/标志非法 —— 要么是 FIFO 里读到半包/脏数据，要么是上一个崩溃实例留下的通道状态没清干净。两种解释都指向同一个方向：**重启后通道状态没有完全 teardown**。

### 2.2 首次加载 10.5s vs 重试 0.58s（差 18 倍）

重试时固件已在 page cache，所以快。含义：**首次启动那一次，正好压在系统 I/O 最重的窗口里**（此时 eMMC 还在读 rootfs、wifi 校频、rc 脚本全在跑），而重试时系统已经空转 40s 完全静止。

首次启动不是"正常那一档"，而是"最差那一档"。这解释了为什么"重试必成"——不只是时间推后，而是**系统负载与初始化完成度完全不同**。

### 2.3 重启后 `bam-dmux: Channel already open: 0..7`

143 成功那次启动，8 个 bam-dmux 通道全部报 "already open"。这是 rproc 恢复后 teardown 不完整的直接证据：新的 modem 实例复用了上一实例残留的通道对象。这与 2.1 的"脏 FIFO"是同一类问题（残留状态跨重启泄漏）。

### 2.4 remoteproc coredump 能力存在但没开

两台都有：
```
/sys/class/remoteproc/remoteproc0/coredump      → disabled
/sys/class/remoteproc/remoteproc0/recovery      → enabled
/sys/kernel/debug/remoteproc/remoteproc0/{crash,coredump,carveout_memories,resource_table}
```
设备上没有 `/dev/mem`，所以没法直接 dump mpss 区（0x86800000, 87MB）。**devcoredump 是唯一能拿到 modem 崩溃现场的手段**，而原文档从未用过——整个"最可疑是 RFFE/RFIC"的结论是纯推理，没有一份 modem 内部数据支撑。

### 2.5 首次启动时时钟树尚未定稿

```
[26.44] gcc-msm8916 1800000.clock-controller: sync_state() pending due to 22000.rng
[26.44] gcc-msm8916 1800000.clock-controller: sync_state() pending due to 1d00000.video-codec
```
`sync_state()` 没完成意味着 GCC 还没进入最终状态（未用时钟可能被关）。首次启动就发生在"时钟状态未定稿"的窗口内，重试时已定稿。这条与 2.2 一样，属于"首次启动所处的系统状态与重试不同"的证据。

---

## 三、对原文档结论的修正

| 原结论 | 复核结果 |
|---|---|
| 换固件此路不通 | ✅ 维持（这次没动固件，且实测两次启动的固件路径一致） |
| rmtfs 时序排除 | ⚠️ 部分维持：rmtfs 自身不阻塞；但"主机侧无关"过头了，**内核 rpmsg 名称服务握手失败与崩溃 100% 共现** |
| 卡死在"与主机建立任何通信之前" | ❌ **不成立**：modem 已宣告 SMD 服务（`is now up` 后 1ms 主机就收到包），卡死发生在**名称服务握手之后** |
| 根因是板级 RFFE/RFIC 硬件边际 | ⚠️ 降级为待验证假设之一。目前证据更支持"重启后通道/FIFO 残留 + 主机名称服务握手失败"，因为 dog 卡死与 fail-announce 一一对应，而纯硬件问题不会和一行内核日志严格同步 |
| 现有兜底（remoteproc 自动重试）已足够 | ⚠️ 可接受但很浪费：4 次 × 40s = 160s。见方案 A |

---

## 四、文档之外的六条办法（按性价比排序）

### A. 快速失败检测 + 立即重启：把 187s 压到 15s 以内
**不依赖根因，今天就能上。** 现状是每次失败都要等满 modem 内部 40s 看门狗；但失败信号在 up 后 1ms 就出现在 dmesg 里，端口在成功时 1s 内必出。所以判据可以做到秒级：

```sh
#!/bin/sh
# /usr/bin/modem-fast-retry.sh
R=/sys/class/remoteproc/remoteproc0
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -c /dev/wwan0qmi0 ] && exit 0
    [ "$(cat $R/state)" = "running" ] && echo stop > $R/state
    echo start > $R/state
    n=0
    while [ $n -lt 80 ]; do          # 8s 内必须出 qmi 口，否则判定本次握手失败
        [ -c /dev/wwan0qmi0 ] && exit 0
        busybox usleep 100000; n=$((n+1))
    done
    logger -t modem-retry "attempt $i: no qmi port in 8s, restarting"
done
exit 1
```
- 实测 `stop` 在停滞态只需 ~0.6s（"port failed halt" 超时后强复位），成本可忽略。
- 期望：最坏 10 次 × (8s + 0.6s) ≈ 90s；典型 2~4 次 ≈ **20~35s**，比现在 105~187s 好一个数量级。
- 判定：连续 5 次开机，`dmesg | grep -c "handling crash"` 应为 0（因为我们抢在看门狗之前就重启了），且 `wwan0qmi0` 出现时间 < 40s。
- 风险：极低。只是把"被动等 40s"换成"主动 8s 判定"。

### B. 把首次启动推到系统静止之后（验证"首次启动状态最差"假设）
`/etc/init.d/qmi-modem-410-init` 里已有 `DELAY=0` 这个旋钮，改成 60 即可；更彻底的是把 `S80rmtfs`、`S60qrtr`、`S70modemmanager` 排到 modem 起来之后。
- 原理：2.2 / 2.5 显示首次启动处在 I/O 高峰且 GCC 未定稿，重试时系统已静止。若故障源于此，推迟即可 0 崩溃。
- 判定：连续 5 次开机 `handling crash` = 0，且 `failed to announce new service` 不再出现。
- 若推迟后**依然崩**且仍有 fail-announce → "系统负载/时钟"这条排除，转向 C。

### C. 决定性实验：只起 modem，不起任何 rpmsg 消费者
这是唯一能把"主机握手竞争"和"modem 自身问题"分开的实验，成本 2 分钟：
```sh
/etc/init.d/rmtfs stop; /etc/init.d/qrtr stop; /etc/init.d/modemmanager stop
echo stop > /sys/class/remoteproc/remoteproc0/state
echo start > /sys/class/remoteproc/remoteproc0/state
sleep 50; dmesg | tail -30
```
- 若**仍出现 fail-announce 并崩** → 说明是内核与 modem 之间的裸握手问题，与用户态无关；
- 若**不再出现 fail-announce、不崩** → 锁定用户态在 modem 刚 up 时抢着打开 `/dev/rpmsg_ctrl*` 导致宣告失败，原文档"rmtfs 排除"需要重写，修法是把 rmtfs/qrtr 排到 modem 通道稳定之后再启动。
- 建议顺序：先做 C，再做 A/B。C 出结果后 A/B 的目标就明确了。

### D. 打开 coredump，把"猜 RFFE"换成"看现场"
```sh
echo enabled  > /sys/class/remoteproc/remoteproc0/coredump
echo disabled > /sys/class/remoteproc/remoteproc0/recovery   # 崩了不自动重启，保留现场
# 重启 → 等 60s（此时已崩但停在原地）→ 取走 dump
ls /sys/class/devcoredump/
cat /sys/class/devcoredump/devcd0/data > /tmp/mpss.dump     # 设备无 sftp-server，用 ssh 管道取回
cat /sys/class/devcoredump/devcd0/data | ssh root@host 'cat > /tmp/mpss.dump'
```
- 内存 380MB，空闲 191MB + 121MB cache，dump 规模可行，但**别落在 tmpfs**，直接管道取走。
- 分析目标：dog 任务当时的 PC / 调用栈落在哪个函数（是等主机的 smd 读、还是轮询 RFFE 寄存器）。这一步能一锤定音，也是发 upstream issue 唯一有说服力的材料。
- 注意：`recovery=disabled` 期间基带不会自愈，做完实验立刻改回 `enabled`。

### E. 冷机 vs 热机对照（补齐文档最大统计缺口）
文档说"约半数开机不崩"，但所有试验都在热重启下做的，没有冷热对照。建议：
- 拔电冷置 10 分钟 → 开机 → 记录首崩次数，× 5 次；
- 紧接着热重启 × 5 次。
- 若冷机显著更差 → 支撑"TCXO/RFIC 模拟电路预热 + 冷启动 VBAT 跌落"这一族硬件假设，对策转向硬件（加大 bulk 电容、查 26MHz TCXO 起振、检查 RF 前端上电次序），软件上则用 B 的"空转 60s 再启 modem"规避。
- 若冷热无差异 → 硬件假设进一步弱化，集中打 C/D。

### F. 通道 teardown 不完整（可提 upstream 的具体缺陷）
`bam-dmux: Channel already open` 与"脏 FIFO 导致名称服务解析失败"是同一类问题：rproc 恢复后旧通道对象没被完全销毁。可以做成一个可提交的 issue 点：
- 复现：一次开机内多次 `stop/start`，观察 `Channel already open` 出现频次与 fail-announce 的相关性；
- 若能证明"清干净通道后再 start 就不崩"，那才是真正的解法（内核侧在 recovery 前 teardown）。

---

## 五、建议执行顺序

1. **C**（2 分钟，决定方向，不重启设备）
2. **A**（立刻改善体验，187s → ~30s）
3. **B**（若 C 指向用户态竞争，B 就是最终修法）
4. **D**（无论 C 结果如何都要做，作为 upstream 证据）
5. **E**（等有空档时做，用于判定要不要动硬件）

判定标准统一为：**连续 5 次开机 `dmesg | grep -c "handling crash"` = 0，且 `wwan0qmi0` 在 30s 内出现**。

---

## 七、实验已经跑了一轮（2026-11-03 23:00 前后，216/JZ02 实机）

### 7.1 最重要的副产品：故障可以 12 秒复现，不用重启

手动 `stop` → `start` 一次，8~12s 内就能判定这次握手干不干净。**整个后续实验不用再重启设备、不用再等 3 分钟**，这是之前文档做不到的（它的实验成本是"每次改完重启 + 等 215s"）。

### 7.2 逐层剥离的结果

| 场景 | 轮次 | announce_fail | 出端口 |
|---|---|---|---|
| 全部消费者在跑（基线） | 3 | 2 | 1 |
| 停 ModemManager + smsrelay + qmi 初始化，**只留 rmtfs** | 4 | 2 | 2 |
| **全部用户态 rpmsg 客户端停掉** | 5 | **0** | **0** |
| 重新拉起 rmtfs 后 | 2 | 0 | 1（第 1 轮 rmtfs 刚起还没注册完，也算失败） |

补充第四组实验后，第 2 条结论必须撤回。

| 场景 | 轮次 | announce_fail | 出端口 |
|---|---|---|---|
| 全部消费者在跑（基线） | 3 | 2 | 1 |
| 停 ModemManager + smsrelay + qmi 初始化，**只留 rmtfs** | 4 | 2 | 2 |
| **全部用户态 rpmsg 客户端停掉** | 5 | **0** | **0** |
| **rmtfs 在 modem start 后 0.2s 才拉起** | 3 | **0** | **3** |

**自我修正**：不能从"只留 rmtfs 2/4 复现"推出"rmtfs 是触发源"——第四组反向结果直接和它冲突（rmtfs 确实是活的、确实打印了 `registering services`，但 3/3 干净）。而且"零用户态 5/5 干净"本身带语义重复：没有服务要宣告，自然不会出现"宣告失败"。

所以**触发源仍未锁定**。能站得住的只有三条：

1. **失败信号在 `is now up` 后 0.7ms 就出现在 dmesg，且与本次启动失败 100% 相关**（12+ 次启动样本无例外）——这是可以当判据用的。
2. **失败后 modem 不会自行恢复**，必然等满 40s 看门狗；成功时端口 1s 内必出。两者差 40 倍。
3. 因此**主动重启可以完全绕过 40s 空等**，且不依赖根因。

### 7.3 方案 A 已验证（同时踩到一个坑）

- 慢节奏（约 13s/轮）手动重启约 16 次，`handling crash` 计数始终停在开机时的 4，**一次 dog 都没触发**。
- 但有一次**连续 6 轮快节奏重启**，内核直接卡死，被 procd 的硬件看门狗复位整机：uptime 归零、`/sys/fs/pstore` 无记录、SSH 会话被掐断。重启原因是 `hotplug-gcreboot`（USB 断开时只重启 gc 服务，不是它），`panic_on_oops=0`，`/dev/watchdog0` 由 `watchdogd` 持有——即**内核 hang 住导致看门狗超时**。

结论：A 的方向对，但**不能无脑循环**，必须限次 + 留间隔。这条在部署里是硬约束。

### 7.4 守护脚本两版实测对比

| 版本 | 判据 | 最坏（5 次尝试）总耗时 |
|---|---|---|
| 原始流程 | 等 modem 自家看门狗 | **187s**（4×40s + 加载） |
| v1 | 启动后 15s 无端口即重启 | 85s |
| **v2（推荐）** | 嗅 dmesg 失败信号，失败即重启 | **37s** |

v2 的日志实证：
```
23:21:00 attempt 1: starting modem
23:21:04 attempt 1: handshake failed, restarting    ← 4s 判定，不是 40s
...
23:21:35 attempt 5: starting modem
23:21:37 ready on attempt 5
```
典型情况（1~2 次尝试）耗时 5~12s。

> ⚠️ **但这个 37s 的代价是拿设备稳定性换的，见第八节。跨设备复验时，同样的快速重试把 SP970 卡死到必须断电。**
> 结论修正：**方案 A 不能作为无人值守的自动重试**，最多只允许"额外 1 次"尝试。

### 7.5 因果链：确定的部分与待定的部分

```
【确定】主机 rpmsg 名称服务握手失败（dmesg 有明确信号，+0.7ms）
   ↓
【确定】modem 初始化不再推进，40s 后自家看门狗 dog.c:1498 报错
   ↓
【确定】remoteproc 自动 recovery；重来一次若握手干净 → 0.6s 内通道全通
```
```
【待定】握手为什么失败：用户态注册时机撞车？内核 SMD FIFO 跨重启残留？
       还是 modem 侧 SMD 尚未就绪就收到了主机的宣告包？
```
`failed while handling packet from 0:-2` 是与失败共现的第二个症状（主机解析后续包时标志位非法），提示 FIFO 里读到半包或脏数据——这更偏向"残留/时序"而不是"硬件"。

原文档"最可疑是 RFFE/RFIC 板级硬件"这一条，目前的证据**不足以支持**：纯硬件问题不会和一行内核日志严格同步出现，也不会因为"重来一次"就 100% 自愈。

### 7.6 coredump 已经抓到（但读不出语义）

在设备自然崩溃循环期间打开 coredump，拿到一份完整现场：

| 项 | 值 |
|---|---|
| 大小 | 77,737,178 B（74.1 MB） |
| 格式 | ELF32 core，23 个 PT_LOAD |
| 基址 | 0x86800000（mpss 保留区） |
| 覆盖 | 0x86800000 ~ 0x8a801000 |

解析结论：
- `dog.c` 只作为 rodata 里的**文件名表**出现（va=0x881f15c1 一带是成片的 `.c` 名字表），断言文本是运行期用 file:line 拼出来的；
- 全文检索 `stalled initialization` / `Watchdog detects` 均 **0 命中**，所以别指望从裸 dump 里直接读出"卡在哪一行"；
- 这份 core 的正确用途是：**交给 upstream / 有符号表（modem ELF symbols）的人做符号化解析**，而不是自己硬读。

### 7.7 交付物

- `files/usr/bin/modem-guard.sh`：v4 守护脚本；`files/etc/init.d/modem-guard`：开机自启入口（`START=98`，后台执行）。
  两者随镜像进入 `/usr/bin/` 与 `/etc/init.d/`，**默认不启用**——需要 `/etc/init.d/modem-guard enable` 才会在开机时运行。已实测：JZ02 上启用有收益，SP970 上负收益，见第十节。
- 接入方式建议（二选一）：
  - 在 `/etc/init.d/qmi-modem-410-init` 的 `start_service()` 里，先跑 `modem-guard.sh`，再启动原有等待逻辑；
  - 或新建 `S98modem-guard`，排在 `S80rmtfs` 之后、`S99qmi-modem-410-init` 之前。
- 脚本行为：最多 5 次尝试，每次失败判定后隔 5s 重启，全程写 `/var/log/modem-guard.log`，超限只记日志不自动 reboot（把决定权留给人/上层策略）。
- 其余三条（B 推迟启动、D coredump、E 冷热对照）在 7.5 的"待定"被证实之前都不值得投入硬件改动。

---

## 八、跨设备复验：脚本把 SP970 卡死了（重要，结论要改）

### 8.1 143/SP970 上的实测过程

| 步骤 | 结果 |
|---|---|
| 部署 `/usr/bin/modem-guard.sh` | 成功 |
| 第 1 次验证（停基带 → 脚本拉起） | **2 秒，attempt 1 即成功** |
| 连续第 2、3 次（每轮 stop→等 3s→脚本→等 12s） | 约第 5~6 个 stop/start 之后，**设备失联** |

失联表现：
- ping 由"全丢"变为"偶发 1/3 回包"
- 22 / 80 / 443 全部连接超时
- ARP 表里没有它的条目（本机 MAC 为 02-00-01 前缀，由 serialno 派生）
- 持续 5 分钟以上未自行恢复 → **需要断电重启**

### 8.2 和 216 那次对照，规律很清楚

| 设备 | 触发条件 | 结果 |
|---|---|---|
| 216/JZ02 | 连续 6 轮 stop/start（约 13s/轮） | 内核卡死，看门狗复位整机（uptime 归零） |
| 143/SP970 | 约 5~6 轮 stop/start（约 10s/轮） | 内核卡死，**看门狗没救回来**，需断电 |
| 216/JZ02 | 自然恢复路径（40s 间隔，每次开机 1~5 轮） | 几十次循环，从未卡死 |

**两台的判别变量不是次数，是间隔。** 40s 间隔怎么折腾都没事；10~13s 的密集重启在 5~6 轮后必然出事。这和之前观察到的 `bam-dmux: Channel already open: 0..7` 是同一个病根：**上一轮的 SMD / bam-dmux 通道还没拆完，下一轮就去重开，导致 teardown 死锁**。

### 8.3 因此结论要改

1. **方案 A（快速重试）降级**：不能做成无人值守的循环。它把"慢 2 分钟"换成了"设备可能整机失联、要人到现场断电"，这个交换不划算。
2. **可接受的形态**：只允许"额外 1 次"重试（脚本传参 `1`），失败就交回内核自然恢复。收益有限但风险可控。
3. **真正的头号问题变了**：不再是"基带启动崩"，而是**连续 stop/start 会导致 teardown 死锁、把整机拖死**。这个比原问题严重得多——原问题最坏是慢 3 分钟，这个是整机不可用。
4. **上游 issue 应该合并成一条**：`qcom_q6v5_mss` / `qcom_smd` 在 recovery 路径上，通道未完全销毁就允许下一次启动；建议把"关闭所有 rpmsg 通道并等待完成"做成 recovery 的前置步骤。附本次的 74MB core 和 `Channel already open` 日志。
5. **运维层面**：任何自动化里碰 `/sys/class/remoteproc/*/state` 都必须串行 + 间隔 ≥40s，否则会复现 8.1。

### 8.4 8.1 之后设备状态

- 216：正常。三端口齐全，rmtfs/ModemManager/smsrelay 全在跑，crash 计数 5，uptime 正常增长。
- 143：**需人工断电重启**。恢复后建议先确认 `/dev/wwan0*` 三个端口、`crash` 计数归零，再决定是否继续做实验。

---

## 六、命令附录

```sh
# 崩溃计数与时间线
dmesg | grep -ac "handling crash"
dmesg | grep -aE "is now up|fatal error|failed to announce|handling packet from|Channel already open"

# 每次启动是否握手干净（A/B/C 的核心判据）
dmesg | grep -a "is now up" | grep -v a204000
dmesg | grep -a "failed to announce new service"

# 手动重启基带（安全，实测 <1s）
echo stop  > /sys/class/remoteproc/remoteproc0/state
echo start > /sys/class/remoteproc/remoteproc0/state

# 现状确认
cat /sys/class/remoteproc/remoteproc0/{state,recovery,coredump}
ls /dev/wwan0at0 /dev/wwan0qmi0
```

---

## 九、更正与最终结论（23:50 更新，此前第八节的归因撤回）

### 9.1 撤回"脚本把 143 卡死"的判断

143 恢复后第一时间的证据：

| 检查项 | 结果 | 含义 |
|---|---|---|
| `uptime` | 3 分钟 | **是重启过**，不是内核挂死 |
| `/var/log/modem-guard.log` | 不存在 | `/var` 是 tmpfs，重启即清空 → 佐证重启 |

**但重启的成因无法归因。** 重启会把 dmesg、tmpfs 日志全部抹掉，我手上没有任何能证明"是密集 stop/start 导致"的证据。而业主指出：**该机型本身就有重启后失联的已知现象**。这条更符合后来观察到的另一组事实——

216 从 23:13 那次重启之后，`uptime` 一路连续增长到 2143s，期间经历了多轮 stop/start（含 3 次脚本验证），**再没重启过**。如果"密集重启必然拖死内核"成立，它不该在后续这么多轮里毫发无伤。

所以：**第八节 8.3 的 1/3/5 条作废**。准确表述应为"观察到我方操作期间设备重启过两次，但无法排除设备自身重启"，而不是"脚本导致整机卡死"。

### 9.2 但真的抓到了我自己脚本的一个 bug

216 那次 `MAX_TRY=2` 两个尝试都失败后，日志是：

```
23:44:05 attempt 2: handshake failed, restarting
23:44:10 FAILED after 2 attempts, leaving modem as-is
```

随后观察 160 秒：`ports=0`、`crash` 计数纹丝不动。原因不是"内核没接上"，而是——**最后一轮先执行了 `stop` 然后才退出，等于把基带关机走人**。modem 已经关机，自然不会再有看门狗超时，内核的 crash-recovery 也就永远不会触发，结果是基带被静默关闭。

这是我 v2 里的真实 bug，已修：**最后一次尝试失败时不再 `stop`，必须把 modem 留在 `running`**，让内核的看门狗照常接管。

### 9.3 修复后的两台实测（各一轮，带 uptime 校验）

| 设备 | 起始 | 过程 | 结果 | 期间是否重启 |
|---|---|---|---|---|
| 143/SP970 | 3 端口 | attempt 1 失败(3s) → attempt 2 成功(1s) | **10s，3 端口恢复** | 否（uptime 213→226s 连续） |
| 216/JZ02 | state=offline，0 端口 | attempt 1 失败 → 2 失败 → 3 成功 | **29s，3 端口恢复** | 否（uptime 连续 +29s） |

两台 `crash` 计数在过程中都没有增加——因为都在 40s 看门狗之前就判掉并重来了。

### 9.4 最终形态（参数与定位）

- `STOP_GAP=10`、`MAX_TRY=3`：最多额外 2 次，失败后把 modem 留在 running。
- 日志落 `/root/modem-guard.log`（闪存），**重启后仍然保留**——这是这次教训直接换来的改动，以后再有异常重启就有据可查。
- 定位：**人工/半自动工具**，不建议接入无人值守的循环。理由不是"会拖死内核"（已撤回），而是：最坏情况它只节省约 30s，而收益上限不高，没必要为此增加自动动作。
- 如果要接开机流程，建议只跑默认参数一次，失败就交给内核按 40s 节奏慢慢恢复——那条路径几十次循环从未出过问题。

### 9.5 仍未解决的核心问题（不变）

握手为什么时好时坏，仍未定位。能确定的还是那三条：信号 up+0.7ms 可见、与结果 100% 相关、失败后必等 40s。要根治只能走内核侧（`qcom_smd` announce 失败重试），或拿 74MB core 配合 modem 符号表做符号化分析。

---

## 十、真实重启实测（2026-11-03 23:58 ~ 11-04 00:16）

此前所有验证都是"手动 stop 后跑脚本"，起点是干净的，跟真实开机不是一回事。这一节是真重启的实测结果。

### 10.1 v4 针对真机重启改了什么

| 真机暴露的问题 | v4 的修法 |
|---|---|
| "端口出现"≠成功：SP970 会先出 qmi0，3.4s 后才崩（`smd_dsm_memcpy.c:297`） | 增加 15s 稳定性窗口，期间不许有新 crash、qmi0 不许消失 |
| 崩溃恢复后拿到残留 bam-dmux 通道（`Channel already open: 0..7`） | 端口不全/期间崩过 → 补一次干净 stop/start |
| 首次 mpss 加载要 10.5s（eMMC） | 首轮窗口 45s，重试窗口 20s |
| rc.d 里脚本阻塞会拖累 S99 | 由 `/etc/init.d/modem-guard`（START=98）后台拉起 |

### 10.2 216 / JZ02：有效，但有一个遗留问题

| 指标 | 基线（无守护） | 加守护 |
|---|---|---|
| 出齐三端口 | **187s** | **79s** |
| 崩溃次数 | **4 次** | **1 次** |

守护日志：
```
23:59:21 [boot] start, crash_count=0 ports=0
23:59:59 [boot] attempt 1: crashed or ports incomplete (crash=1 ports=0)
00:00:11 [boot] attempt 1: clean restart issued
00:00:13 [boot] attempt 2: handshake failed (stall)
00:00:24 [boot] attempt 2: clean restart issued
00:00:40 [boot] healthy on attempt 3 (ports=3)
```
时间线对得上：up 24.3 → qmi0 25.1 → crash #1 31.1 → 守护 38s 判定 → 重启 → up 43.2 但 announce 失败（stall）→ 再重启 → up 55.9 → qmi0 56.7 → 稳定 15s → 79s 判定健康。

**遗留问题**：at0 在 attach 后 48s（105.08s）单独掉线，at1 和 qmi0 都在，crash 计数没变。之后再手动干净重启一次，三端口稳定通过 75s 观察。这说明 at0 掉线是独立于守护脚本的另一个毛病，不是守护引入的（143 上没跑守护也发生了，见下）。

### 10.3 143 / SP970：负收益，已在设备上禁用

守护日志：
```
23:53:40 [boot] start, crash_count=0 ports=0
23:53:43 [boot] attempt 1: crashed or ports incomplete (crash=1 ports=0)
23:57:35 [boot] attempt 1: clean restart issued
23:57:37 [boot] attempt 2: handshake failed (stall)
23:57:48 [boot] attempt 2: clean restart issued
23:57:50 [boot] attempt 3: handshake failed (stall)
23:57:50 [boot] last attempt; leaving modem RUNNING for kernel recovery
```
它发出的两次重启**各自又触发了一次 stall**（时间线里 33.46s、46.20s 两次 up 后紧跟 `failed to announce`），3 次额度耗尽后放弃，当时 `ports=0`。最后是**内核自己**在 86s 崩一次、恢复，112s 时三端口齐全。

原因不难理解：每次 start 本身就有 50%~70% 概率 stall，由谁触发都一样。守护脚本只是在赌硬币，赌输三把就把额度用光，反而比不干预更差（不干预至少还有内核那条"40s 间隔、屡试不爽"的路）。

**处置**：已在 143 上 `/etc/init.d/modem-guard disable`，S98 软链已移除。216 上保留启用。

### 10.4 新发现：at0 会在 attach 后约 40 秒单独掉线

| 设备 | at0 attach | at0 掉线 | 间隔 | 当时是否崩 |
|---|---|---|---|---|
| 143（无守护） | 23.78s | 62.65s | **38.9s** | 否 |
| 216（有守护） | 56.46s | 105.09s | **48.6s** | 否 |

两台都发生在 #40s 量级，且与崩溃无关，at1/qmi0 不受影响。这对短信中继是致命的（smsrelay 走 at0）。
好在**再干净重启一次后 at0 能稳定**（216 上盯了 75s 没掉）。所以这是一个"某些启动轮次会坏"的概率问题，机制未明，暂记为待查项。

### 10.5 当前部署状态

| 设备 | `/usr/bin/modem-guard.sh` | 开机自启 | 依据 |
|---|---|---|---|
| 216 / JZ02 | v4 已部署 | **启用**（S98） | 187s→79s，崩 4→1 |
| 143 / SP970 | v4 已部署 | **已禁用** | 实测负收益，见 10.3 |

### 10.6 at0 掉线的后续确认（00:10）

- 143 在 434s 时 at0 也掉了（与 216 同病）；做一次干净 stop/start 后三端口恢复，**连续观察 140 秒未再掉**。
- 216 同期观察 75 秒未再掉。
- 因此 at0 掉线是"**某些启动轮次会坏、换一次干净的就好**"的概率问题，不是必然后果；触发条件未知，但与是否崩溃、是否有守护脚本都无稳定关联。

### 10.7 结论（最终）

1. **守护脚本不能统一上线**。216 收益明确（187s→79s、崩 4→1）；143 实测负收益（自身重启又触发 stall，额度耗尽后 ports=0）。已按机型分别启用/禁用。
2. **更深一层的问题是"单次启动本身就有 50%~70% 失败率"**，所以任何重试都只是掷硬币，重试次数不等于收敛。要根治只能回到内核侧：`qcom_smd` announce 失败不重试这一条。
3. **at0 约 40s 掉线**是这次真机重启才暴露出来的新问题，影响短信中继，机制未明，建议单独立项跟踪（可用同一套 `/root/modem-guard.log` + dmesg 时间线方法）。

### 10.8 216 连做两次真实重启的复测（00:10 / 00:13）

守护脚本保持启用，清空日志后连做两次 `reboot`：

| 轮次 | 守护日志 | 端口出现 | 崩溃 | 判定健康 | at0 稳定性 |
|---|---|---|---|---|---|
| 第 1 次 | 00:10:51 start → 00:11:38 **healthy on attempt 1** | 23.76s | **0** | ~47s | 稳定 152s |
| 第 2 次 | 00:13:48 start → 00:14:39 **healthy on attempt 1** | 23.17s | **0** | ~51s | 稳定 90s+ |

两轮都是 attempt 1 直接过，守护脚本**没有出手**。

这里必须说清楚一个统计上的坑：**这两轮本身就没坏，所以它们证明的是"加了守护不会变差"，并不能证明"守护有用"**。按 50%~70% 的失败率，两次都干净本来就有 9%~25% 的概率。守护的价值只在启动失败的那次体现——也就是 10.2 那一轮：崩 1 次 + stall 1 次，两次重启后 79s 出齐三端口（基线 187s）。

累计在 216 上带守护跑了 3 次重启：

| 轮次 | 崩溃 | 守护出手 | 出齐三端口 |
|---|---|---|---|
| 23:59 | 1 次 | 2 次重启 | **79s** |
| 00:10 | 0 次 | 无 | 23.76s（端口）/ 47s（判定） |
| 00:13 | 0 次 | 无 | 23.17s / 51s |

3 次全部拿到三端口，没有一次出现 143 那种"额度耗尽、ports=0"。
