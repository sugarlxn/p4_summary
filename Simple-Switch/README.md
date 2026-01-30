# Simple-Switch

```
         _                 __                         _ __       __  
   _____(_)___ ___  ____  / /__        ______      __(_) /______/ /_ 
  / ___/ / __ `__ \/ __ \/ / _ \______/ ___/ | /| / / / __/ ___/ __ \
 (__  ) / / / / / / /_/ / /  __/_____(__  )| |/ |/ / / /_/ /__/ / / /
/____/_/_/ /_/ /_/ .___/_/\___/     /____/ |__/|__/_/\__/\___/_/ /_/ 
                /_/                                                  

```

**[中文](./README.md) / [English](./README_en.md)**

这个是一个基于P4语言实现的简单2层交换机，使用9180x32 p4交换机 sde9.2.0

实现的功能：

- 交换机2层转发
- mac地址自学习、老化，即支持端口热插拔
- arp请求广播


## 编译

```
./<path to your sde9.2.0>/p4_build.sh ./<path to this project>/my_simple_l2.p4
```

## 如何使用

```
# 运行p4程序
./run_switch.sh -p my_simple_l2
# 使用bfshell 运行setup脚本
./run_bfshell.sh -b ./my_simple_l2_setup.py -i 
```

- 如果出现以下错误信息：
```
error opening /dev/bf0
ERROR: Device mmap failed for dev_id 0
please load driver with bf_kdrv_mod_load script. Exiting...
```
执行以下命令：
```
$SDE/install/bin/bf_kdrv_mod_load $SDE_INSTALL
# SDE=/root/bf-sde-9.2.0
# SDE_INSTALL=/root/bf-sde-9.2.0/install
```

- bfshell简单使用, 配置端口，使能端口，查看端口状态
```
bfshell> ucli
pm
# 添加端口 port-add <port_nanme> <speed> <mode> 
port-add -/- 10G none
port-add 10/- 10G none
# 使能端口
port-enb -/-
port-enb 10/-
# 查看已使能端口信息
show
# 查看所有端口状态
show -a
```
- bfshell 查看流表
```
bfshell> bfrt_python
bfrt_python> bfrt
bfrt> my_simple_l2
bfrt.port> pipe
bfrt.port.pipe> ingress
```

## 数据平面实现方法（my_simple_l2.p4）

本项目的数据平面代码位于 [Simple-Switch/my_simple_l2.p4](Simple-Switch/my_simple_l2.p4)，基于 Tofino 的 TNA 架构，主要由 **头部定义、元数据、解析器、Ingress 控制、Deparser 以及 Egress 管线** 几部分组成。下面按培训角度逐步说明。

### 1. 头部与元数据结构

- 以太网头部 `ethernet_h`
      - 字段：`dst_addr`、`src_addr`、`ether_type`。
      - 用于后续基于 MAC 地址的转发表匹配。
- VLAN 头部 `vlan_tag_h`
      - 字段：`pcp`、`cfi`、`vid`、`ether_type`。
      - 用于识别带 VLAN Tag 的二层报文。
- IPv4 头部 `ipv4_h`
      - 这里只做基本解析，并未在本示例中进行三层转发，仅用于扩展示例。
- Ingress 头部聚合结构 `my_ingress_headers_t`
      - 包含 `ethernet`、`vlan_tag`、`ipv4`，方便在 Ingress 控制中统一访问。
- 端口元数据 `port_metadata_t`
      - `port_pcp`、`port_vid`、`l2_xid`：从硬件端口属性中解包，后续用于多播排除（source pruning）。
- Ingress 全局元数据 `my_ingress_metadata_t`
      - `mac_move`：记录 MAC 是否从其他端口迁移（旧端口 XOR 新端口）。
      - `is_static`：MAC 是否为静态配置（防止自动老化覆盖）。
      - `smac_hit`：源 MAC 查询是否命中。
      - `ingress_port`：进入交换机的端口号。

### 2. IngressParser：报文解析流程

Ingress 解析器负责从线速数据包中提取头部与端口属性：

1. `state start`
       - 提取 `ingress_intrinsic_metadata_t`（硬件内部元数据，如 `ingress_port` 等）。
       - 调用 `port_metadata_unpack<port_metadata_t>(pkt)` 解包端口属性到 `meta.port_properties`。
2. `state meta_init`
       - 初始化 `mac_move = 0`、`is_static = 0`、`smac_hit = 0`，记录 `ingress_port`。
       - 跳转到 `parse_ethernet`。
3. `state parse_ethernet`
       - 提取以太网头部 `hdr.ethernet`。
       - 根据 `ether_type` 分支：
             - `0x8100`（`ETHERTYPE_TPID`）→ `parse_vlan_tag`。
             - `0x0800`（`ETHERTYPE_IPV4`）→ `parse_ipv4`。
             - 其他 → `accept`。
4. `state parse_vlan_tag`
       - 提取 VLAN 头部 `hdr.vlan_tag`，再次根据内部 `ether_type` 判断是否 IPv4。
5. `state parse_ipv4`
       - 提取 IPv4 头部 `hdr.ipv4`，然后 `accept`。

在培训时可以强调：**解析器只做“切包+识别协议”，不做转发决策，所有转发逻辑都在后面的 Ingress 控制中完成。**

### 3. Ingress 控制：MAC 学习与转发逻辑

Ingress 控制块 `Ingress` 是整个二层交换机逻辑的核心，主要包括：基本动作定义、源 MAC 学习表 `smac`、学习结果处理表 `smac_result`、目的 MAC 转发表 `dmac`，以及 apply 阶段的调用顺序。

#### 3.1 基本动作

- `action send(PortId_t port)`
      - 设置 `ig_tm_md.ucast_egress_port = port`，实现单播转发。
      - 如果定义了 `BYPASS_EGRESS`，会开启 `ig_tm_md.bypass_egress`，直接绕过 Egress 管线（示例中默认未使用）。
- `action drop()`
      - 设置 `ig_dprsr_md.drop_ctl = 1`，让后续阶段丢弃该报文。

#### 3.2 源 MAC 学习表 smac

表定义：

- `table smac`
      - key：`hdr.ethernet.src_addr : exact`（精确匹配源 MAC）。
      - actions：`smac_hit`、`smac_miss`、`smac_drop`。
      - 大小：`size = 65536`。
      - `idle_timeout = true`，支持按空闲时间老化。

相关动作：

- `action smac_hit(PortId_t port, bit<1> is_static)`
      - 由控制面在插入条目时填入 `port` 和 `is_static`。
      - 计算 `meta.mac_move = ig_intr_md.ingress_port ^ port`，如果不为 0 则表示 MAC 从其他端口迁移。
      - 设置 `meta.smac_hit = 1`、`meta.is_static = is_static`。
- `action smac_miss()`
      - 源 MAC 未命中，仅设置默认状态，不做转发或丢弃。
- `action smac_drop()`
      - 对于非法场景（例如检测到静态 MAC 冲突）可以直接丢包并 `exit`。

**说明：** `smac` 表不直接产生转发行为，而是更新元数据，为后续的 `smac_result` 表决策提供输入。

#### 3.3 学习结果处理表 smac_result

- `table smac_result`
      - key：
            - `meta.mac_move : ternary`（三态匹配，可匹配 0、1 或“任意”）。
            - `meta.is_static : ternary`。
            - `meta.smac_hit : ternary`。
      - actions：`mac_learn_notify`、`NoAction`、`smac_drop`。
      - `const entries`：在 P4 程序中直接写死的 4 条规则：
            - `(_, _, 0) : mac_learn_notify()` → 新 MAC（未命中）需要上报控制面学习。
            - `(0, _, 1) : NoAction()` → 已学过且无迁移，保持现状。
            - `(_, 0, 1) : mac_learn_notify()` → 动态 MAC 且发生迁移，通知控制面更新。
            - `(_, 1, 1) : smac_drop()` → 静态 MAC 发生迁移，认为异常，丢弃报文。

动作 `mac_learn_notify()` 的核心是：

- 设置 `ig_dprsr_md.digest_type = L2_LEARN_DIGEST`，告知 IngressDeparser 需要生成学习 digest，通知控制面。

#### 3.4 目的 MAC 转发表 dmac

- `table dmac`
      - key：`hdr.ethernet.dst_addr : exact`。
      - actions：
            - `dmac_unicast`：单播转发。
            - `dmac_multicast`：广播或组播泛洪（用于 ARP 广播等）。
            - `dmac_miss`：未命中，保持默认不转发。
            - `dmac_dorp`：显式丢包（拼写为 dorp，为示例中的小拼写错误）。
      - 默认动作：`default_action = dmac_miss()`。
      - 表大小：`size = IPV4_HOST_SIZE`，常量值 65536。

相关动作：

- `action dmac_unicast(PortId_t port)`
      - 调用 `send(port)`，设置单播出口端口。
- `action dmac_multicast(MulticastGroupId_t mcast_grp)`
      - 设置 `ig_tm_md.mcast_grp_a = mcast_grp` 与 `ig_tm_md.rid = L2_MCAST_RID`，交给 Tofino PRE 模块做多播复制。
      - 利用 `meta.port_properties.l2_xid` 设置 `ig_tm_md.level2_exclusion_id`，实现二层源端口排除（避免把报文回发到入端口）。

#### 3.5 Ingress apply 阶段执行顺序

在 `apply` 中执行顺序为：

1. `smac.apply();` → 源 MAC 学习信息更新到元数据。
2. `smac_result.apply();` → 根据是否新 MAC、是否迁移、是否静态，决定是否发送学习 digest、是否丢弃。
3. `switch (dmac.apply().action_run)` → 执行目的 MAC 查找并根据返回的 action 进行后续处理：
       - 当 `dmac_unicast` 被执行时，增加一个 **源端口剪枝（source pruning）** 检查：
             - 若 `ig_intr_md.ingress_port == ig_tm_md.ucast_egress_port`，表示报文的出端口与入端口相同，此时直接 `drop()`，防止 MAC 环路或错误配置导致的回环。

整体逻辑：

- **先学源 MAC，再查目的 MAC，最后做本端口剪枝。**

### 4. IngressDeparser：生成学习 Digest

Ingress Deparser 的主要职责：

1. 定义 `struct l2_digest_t`，包含：
       - `src_mac`、`ingress_port`、`mac_move`、`is_static`、`smac_hit`。
2. 在 `apply` 中：
       - 若 `ig_dprsr_md.digest_type == L2_LEARN_DIGEST`，则将上述字段打包到 `l2_digest`，发送给控制平面的 digest 回调。
       - 最后 `pkt.emit(hdr);` 重新封装所有头部并发往 Egress 阶段。

培训时可以强调：**P4 程序本身并不“写入流表”，而是通过 digest 和控制面协作，让控制面来下发学习到的 MAC 规则。**

### 5. Egress 管线

- EgressParser 仅提取 `egress_intrinsic_metadata_t`，无额外头部解析。
- Egress 控制 `Egress` 当前不做任何修改，仅作为占位。
- EgressDeparser 直接 `pkt.emit(hdr);`，保持报文不变发出。

整体说明：本示例将所有二层逻辑集中在 Ingress 管线上，便于理解与调试。

## 控制平面实现方法（my_simple_l2_setup.py）

控制平面脚本位于 [Simple-Switch/my_simple_l2_setup.py](Simple-Switch/my_simple_l2_setup.py)，在 bfshell 的 Python 环境中运行，基于 bfrt API 完成 **多播组配置、MAC 学习、老化回调** 等功能。下面按执行顺序说明。

### 1. 环境变量与句柄获取

脚本开头：

- 根据当前 PATH 自动推断 `SDE` 路径，并设置：
      - `os.environ['SDE']`
      - `os.environ['SDE_INSTALL'] = SDE/install`
- 打印 SDE/SDE_INSTALL，方便确认环境。
- 获取 P4 程序句柄：
      - `p4 = bfrt.my_simple_l2.pipe`
      - `p4_learn = p4.IngressDeparser`
- 获取 PRE 相关对象：
      - `node = bfrt.pre.node`
      - `mgid = bfrt.pre.mgid`
      - 同时获取 Ingress 中的 `dmac` 表句柄：`dmac = bfrt.my_simple_l2.pipe.Ingress.dmac`

### 2. 配置二层多播（用于广播/ARP）

为了实现二层广播（如 ARP 请求广播），脚本通过 PRE（Packet Replication Engine）配置多播：

1. 配置多播节点（multicast node）：
       - `node.add(multicast_node_id=0x01, multicast_rid=0x01, multicast_lag_id=[...], dev_port=[...])`
       - 将若干物理端口加入同一个多播节点 ID（例如端口 0,4,8,12,16,20,24,28,32,36）。
       - `node.dump(table=True)` 可查看当前节点配置。
2. 配置多播组（mgid）：
       - `mgid.add(mgid=0x01, multicast_node_id=[0x01], ...)`
       - `mgid.dump(table=True)` 查看 mgid 映射。
3. 在 `dmac` 表中增加一条广播 MAC 规则：
       - `dmac.add_with_dmac_multicast(dst_addr=0xffffffffffff, mcast_grp=0x01)`。
       - 对目标 MAC 为广播地址的报文，使用 Ingress 中的 `dmac_multicast` 动作，发送到 mgid=1 对应的多播组，实现 ARP 广播或未知报文泛洪。

### 3. MAC 学习回调（digest 回调）

在数据面中，当 `smac_result` 决定需要学习或更新某个 MAC 时，会设置 `digest_type = L2_LEARN_DIGEST`，IngressDeparser 会将 `l2_digest_t` 发送给控制面。控制面在脚本中注册回调处理这些 digest：

1. 定义回调函数 `my_learning_cb(dev_id, pipe_id, direction, parser_id, session, msg)`：
       - 通过 `p4.Ingress.smac` 和 `p4.Ingress.dmac` 获取对应表实例。
       - 遍历 `msg` 中的每一条 digest：
             - 从 `digest` 中读取：
                   - `port = digest["ingress_port"]`
                   - `mac_move = digest["mac_move"]`
                   - `mac = digest["src_mac"]`
             - 计算旧端口：`old_port = port ^ mac_move`，用于打印 MAC 迁移信息。
             - 在控制台打印：新学习或迁移的 MAC 与端口。
       - 更新源 MAC 学习表 `smac`：
             - `smac.entry_with_smac_hit(src_addr=mac, port=port, is_static=False, entry_ttl=10000).push()`
             - 这里选择 `is_static=False`，表示这是一条可老化的动态 MAC。
             - `entry_ttl` 设置空闲超时时间，配合数据面的 `idle_timeout` 机制生效。
       - 更新目的 MAC 转发表 `dmac`：
             - `dmac.entry_with_dmac_unicast(dst_addr=mac, port=port).push()`
             - 后续收到发往该 MAC 的报文时将单播转发到对应端口。
       - 返回 0 表示处理成功。
2. 注册/注销回调：
       - 在注册前尝试 `p4_learn.l2_digest.callback_deregister()`，避免重复注册旧回调。
       - 再调用 `p4_learn.l2_digest.callback_register(my_learning_cb)` 完成注册。

培训讲解要点：

- 数据面只负责“检测需要学习的 MAC 并上报”，真正写表的动作由控制平面在回调中完成。
- 每收到一个新 MAC 或迁移 MAC，控制平面会同步更新 `smac` 与 `dmac`，实现“自学习二层交换机”。

### 4. MAC 老化回调（idle timeout）

数据面中的 `smac` 表启用了 `idle_timeout`，当某条条目长时间未被命中时，硬件会触发老化事件，控制面通过回调清理对应条目：

1. 定义老化回调函数 `my_aging_cb(dev_id, pipe_id, direction, parser_id, entry)`：
       - 获取 `smac` 与 `dmac` 表句柄。
       - 从老化条目中读取 key：`mac = entry.key[b'hdr.ethernet.src_addr']`。
       - 打印“老化 MAC 地址”的日志信息。
       - 调用 `entry.remove()` 从 `smac` 表中删除该源 MAC 条目。
       - 再尝试 `dmac.delete(dst_addr=mac)` 删除目标 MAC 条目：
             - 若未找到则打印 WARNING，但不影响其他条目。
2. 配置老化通知：
       - 先关闭老化通知：`p4.Ingress.smac.idle_table_set_notify(enable=False)`，避免遗留配置干扰。
       - 再开启并注册新回调：
             - `enable=True` 表示开启老化通知。
             - `callback=my_aging_cb` 指定回调函数。
             - `interval=10000`：轮询老化事件的时间间隔。
             - `min_ttl` / `max_ttl`：老化时间窗口（如 10s~60s）。

老化机制配合学习机制实现了：**MAC 地址自学习 + 自动老化**，从而支持端口热插拔以及主机上下线的动态环境。

### 5. 控制平面完整执行流程总结

培训时可以用以下步骤串联整个控制平面：

1. 运行 bfshell 并加载 P4 程序：
       - `./run_switch.sh -p my_simple_l2`
       - `./run_bfshell.sh -b ./my_simple_l2_setup.py -i`
2. 脚本自动完成：
       - 设置 SDE 环境变量，获取 P4/表/PRE 句柄。
       - 配置多播节点和 mgid，实现广播/组播转发（主要用于 ARP）。
       - 在 dmac 表中添加广播 MAC 的多播规则。
       - 注册 MAC 学习 digest 回调，监听数据面上报的新 MAC。
       - 注册 MAC 老化回调，定期清理长时间未使用的 MAC 条目。
3. 当主机发送数据帧：
       - 源 MAC 首次出现 → 数据面触发 digest → 控制平面学习并写入 smac/dmac。
       - 目的 MAC 未知或广播 → 命中 dmac 广播规则 → 通过 PRE 在多个端口泛洪。
4. 当某主机长时间无流量：
       - 对应 smac 条目空闲超时 → 硬件触发老化事件 → 控制面删除 smac/dmac 条目 → 资源回收。

## 培训讲解建议步骤

在对他人培训本项目时，可以按照以下顺序组织内容：

1. **整体目标介绍**
       - 说明本项目实现的是“支持 MAC 自学习与老化的二层交换机”，并支持 ARP 广播。
       - 简要介绍硬件平台（如 9180x32）和 SDE 版本（9.2.0）。
2. **数据平面结构讲解（my_simple_l2.p4）**
       - 从头部与元数据结构开始，让学员理解每个字段的作用。
       - 讲解 IngressParser 的状态机，说明如何识别 VLAN / IPv4 报文。
       - 重点讲解 Ingress 控制中的 `smac`、`smac_result`、`dmac` 三张表以及动作逻辑。
       - 说明 Digest 的意义，以及 IngressDeparser 如何打包学习信息。
3. **控制平面脚本讲解（my_simple_l2_setup.py）**
       - 逐行介绍如何通过 bfrt API 获取表句柄、配置多播、注册回调。
       - 结合日志输出演示学习回调和老化回调的实际效果。
4. **实际动手实验**
       - 指导学员编译、运行 P4 程序，并通过 bfshell 配置端口。
       - 通过两台或多台主机互相 ping，观察 MAC 学习与转发表变化：
             - 使用 `bfrt.my_simple_l2.pipe.Ingress.smac.dump(table=True)` 等命令查看表项。
       - 等待一段时间后，观察老化回调输出与表项删除情况。
5. **扩展思考**
       - 如何在本项目上扩展 VLAN 支持、端口隔离、ACL、简单三层转发（IPv4 LPM）等。
       - 如何将静态 MAC 与动态 MAC 策略结合，构建更安全的二层网络。

## 贡献

PRs accepted.

## 许可证

MIT © Richard McRichface
