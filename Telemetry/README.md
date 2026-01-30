1. 设置环境变量
```shell
SDE_INSTALL=/root/onl-bf-sde/install
SDE=/root/onl-bf-sde
PATH=/root/onl-bf-sde/install/bin:$PATH
```
2. 编译运行
```shell
$SDE/install/bin/bf_kdrv_mod_load $SDE_INSTALL
$SDE/p4_build.sh --with-p4c=bf-p4c simple_forward.p4
$SDE/run_switchd.sh -p simple_forward 
```
3. 添加端口
```shell
bf-sde.pm> show -a
bf-sde.pm> port-add 13/0 100G RS  
bf-sde.pm> port-add 14/0 100G RS
bf-sde.pm> port-enb -/-  
bf-sde.pm> show 
```
or
```shell
$SDE/run_bfshell.sh -f port.txt
```

4. 进入bfshell
```shell
$SDE/run_bfshell.sh -b setup.py -i 
```

## Telemetry 功能概述

本目录基于 P4 程序 [Telemetry/mirror_digest.p4](Telemetry/mirror_digest.p4) 和控制平面脚本 [Telemetry/setup.py](Telemetry/setup.py)，实现了针对 RoCEv2（RDMA over Converged Ethernet v2）流量的细粒度网络遥测，核心能力包括：

- **RoCEv2 报文解析**：在数据面解析以太网 / IPv4 / UDP / RoCEv2 BTH/RETH 等头部，识别 RDMA Write 流。
- **随机丢包与重传观测**：通过硬件内置随机数实现可配置的随机丢包，用于触发 RDMA 重传，从而在 Telemetry 中观测重传行为。
- **流级完成时间 (Flow Completion Time, FCT)**：通过对 RDMA Write 首包与尾包时间戳的统计，得到每条 RDMA 流的完成时间。
- **超时/大间隔检测**：对相邻 RDMA 报文间的时间差进行阈值判断，超出阈值的流触发 TimeOut Digest，上报“潜在超时流”。
- **镜像到 CPU**：利用 Tofino 的镜像和 to_cpu 头部，将选定报文复制到 CPU 端进行离线分析或在线监控。

下面分数据平面和控制平面详细介绍，方便培训使用。

## 数据平面实现（mirror_digest.p4）

数据面代码位于 [Telemetry/mirror_digest.p4](Telemetry/mirror_digest.p4)，基于 Tofino 的 TNA 架构，主要模块：

- 头部与元数据定义：支持以太网/VLAN/IPv4/IPv6/TCP/UDP/ICMP 以及 RoCEv2 头部。
- IngressParser：完成 RoCEv2 报文的协议栈解析。
- Ingress 控制：转发、随机丢包、RDMA 识别、时间戳寄存器更新、Digest 触发等。
- IngressDeparser：打包 Telemetry Digest、更新校验和、镜像封装。
- Egress 管线：解析内部镜像头部，将报文封装为 to_cpu 报文发往 CPU。

### 1. 头部与元数据结构

**基础头部**：

- `ethernet_h` / `vlan_tag_h`：标准二层头部，用于基本转发与协议判定。
- `ipv4_h` / `ipv6_h`：三层头部，用于 IPv4/IPv6 转发和解析。
- `tcp_h` / `udp_h` / `icmp_h`：四层头部，主要用于区分不同应用流量。

**RoCEv2 相关头部**：

- `infiniband_bth_h`（BTH）
	- 字段包括 `opcode`、`destinationQP`（目的队列对 QP）、`packetSequenceNumber`（PSN）等，是识别 RDMA 操作类型和会话的关键。
- `infiniband_reth_h`（RETH）
	- 包含 `virtualAddress`、`rKey`、`dmaLength`，用于描述 RDMA Write 操作写入的内存地址和长度。
- `infiniband_icrc_h`、`infiniband_atomiceth_h` 等：为 RoCEv2/IB 协议保留，示例中主要关注 BTH/RETH。

**内部头部与镜像/CPU 头部**：

- `bridge_h`：
	- 包含通用字段 `header_type`、`header_info`，以及 `ingress_port` 等信息。
	- 作为内部头部，标记报文经过 Bridge 处理。
- `ing_port_mirror_h`：
	- 保存入口端口、镜像会话号、入口时间戳（MAC TS 和 Global TS），用于后续 Egress 阶段构造 to_cpu 报文。
- `to_cpu_h`：
	- 这是真正**在线上出现**的 to_cpu 头部，包含 mirror header 同样的信息以及 `pkt_length` 等字段，便于控制面解析镜像报文。

**Telemetry 元数据与 Digest 结构**：

- Ingress 元数据 `my_ingress_metadata_t` 中的关键字段：
	- `src_address` / `dst_address`：源/目的 IP（IPv4）。
	- `src_port` / `dst_port`：传输层端口（TCP/UDP）。
	- `opcode`：RoCEv2 BTH 的操作码，用于区分 RDMA Write 首包/尾包等类型。
	- `destinationQP`：RDMA 会话标识（Queue Pair）。
	- `dmaLength`：RDMA 写入的数据长度。
	- `time_out`：内部超时标志位。
	- `timestamp_diff_1/2/3`：拆分后的 3 段 16bit 时间差，用于匹配时间间隔阈值。
- Telemetry Digest 结构：
	- `digest_t`：
		- 包含 `src_ip`、`dst_ip`、`src_port`、`dst_port`、`opcode`、`ingress_global_tstamp`、`destinationQP`、`dmaLength`。
		- 主要用于**细粒度流统计与 FCT 计算**。
	- `time_out_digest_t`：
		- 包含 `timestamp_diff_1/2/3`，代表 48bit 的时间差拆分结果。
		- 用于**流超时/长间隔检测**。

### 2. IngressParser：RoCEv2 报文解析

解析流程大致如下：

1. `state start`
	 - 提取 `ingress_intrinsic_metadata_t`，并 `pkt.advance(PORT_METADATA_SIZE)` 跳过端口元数据区域。
2. `state init_meta`
	 - 将 `meta` 全部清零，初始化为 0。
	 - 将 `hdr.bridge` 置为 valid，并填充：
		 - `header_type = HEADER_TYPE_BRIDGE`
		 - `ingress_port = ig_intr_md.ingress_port`。
	 - 转到 `parse_ethernet`。
3. `state parse_ethernet`
	 - 解析以太网头部，根据 `ether_type` 决定是否解析 VLAN 或 IPv4：
		 - `ETHERTYPE_TPID` → `parse_vlan_tag`。
		 - `ETHERTYPE_IPV4` → `parse_ipv4`。
4. `state parse_vlan_tag`
	 - 解析 VLAN Tag 后，再根据内部 `ether_type` 判断是否 IPv4。
5. `state parse_ipv4`
	 - 解析 IPv4 头部，并用 `Checksum()` 计算校验和。
	 - 根据 `protocol` 字段：
		 - TCP → `parse_tcp`。
		 - UDP → `parse_udp`。
		 - ICMP → `parse_icmp`。
6. `state parse_udp`
	 - 解析 UDP 头部，通过 `dst_port` 判断是否为 RoCEv2（通常是 4791 端口），命中后跳转 `parse_rdma`。
7. `state parse_rdma`
	 - 解析 RoCEv2 BTH 头部，提取 `opcode`、`destinationQP` 等核心字段。
	 - 根据 opcode 决定是否需要解析额外 RETH、ATOMIC_ETH 等扩展头：例如 RDMA Write 带 RETH 时跳转 `parse_reth`。
8. `state parse_reth`
	 - 解析 RETH，提取 `dmaLength` 和 `virtualAddress`，为 Telemetry 提供流量大小信息。

培训时可以强调：**Parser 只是完成协议栈解析和关键字段提取，为后续 Ingress 控制中的 Telemetry 逻辑提供数据基础。**

### 3. TimeOutPipe：按时间间隔触发 TIMEOUT_DIGEST

`TimeOutPipe` 是一个单独的控制块，主要实现“基于时间间隔的超时检测”：

- `action set_time_out()`
	- 设置 `ig_dprsr_md.digest_type = TIMEOUT_DIGEST`，通知 IngressDeparser 生成超时报文的 digest。
- `table time_out_pkt`
	- key 使用 `timestamp_diff_1/2/3` 的范围匹配（range match），用于表示 48bit 的时间差阈值。
	- actions 为 `set_time_out; NoAction;`。
	- `size = 1`，通常配置单一时间阈值即可。
- 在 Ingress 控制中会实例化 `TimeOutPipe()` 并在适当位置 `time_out_pipe.apply()`，以当前计算得到的时间差作为 key 查询，满足阈值时触发 TIMEOUT_DIGEST。

### 4. Ingress 控制：转发 + 随机丢包 + RDMA Telemetry

Ingress 控制 `Ingress` 是 Telemetry 的核心，主要逻辑包括：

#### 4.1 三层转发相关

- 本例保留了基础的三层转发表：
	- `ipv4_host`：精确匹配 `hdr.ipv4.dst_addr`，动作可设置 `set_nexthop`。
	- `ipv4_lpm`：最长前缀匹配 LPM，默认 `set_nexthop(0)`。
- `nexthop` 表：
	- key：`nexthop_id`。
	- actions：`send`、`drop`、`l3_switch`：
		- `send(port)`：设置 `ig_tm_md.ucast_egress_port`，实现基本转发。
		- `l3_switch(port, new_mac_da, new_mac_sa)`：完成类似三层转发的 MAC 重写，并递减 TTL。

在 Telemetry 场景中，这部分保证 RoCEv2 报文能够正常在交换机间转发。

#### 4.2 随机丢包 random_drop：模拟丢包与重传

- `Random<bit<16>>() random_gen;`
	- 硬件内置随机数发生器，生成 0~65535 的随机值 `random_value`。
- `table random_drop`
	- key 一般会包含 `random_value` 与配置的 `random_value_start` / `random_value_end` 的 range 匹配（完整字段在代码中，可根据需要扩展）。
	- actions：`set_drop`、`clear_drop`：
		- `set_drop()`：`ig_dprsr_md.drop_ctl = 1`，丢弃当前报文。
		- `clear_drop()`：清除 drop 控制位。

通过在控制面设置不同的 `rate`（见后文 setup.py），可以实现例如 1%/5% 等不同丢包率，用于触发 RDMA 协议的重传机制，从而在 Telemetry 中观测重传带来的流完成时间变化。

#### 4.3 入口镜像与 ACL

- `port_acl` 表（端口 ACL）
	- 通过匹配报文的五元组/端口等条件，决定是否对报文进行镜像或镜像+丢弃。
- 关键动作：
	- `acl_mirror(MirrorId_t mirror_session)`：
		- 设置 `ig_dprsr_md.mirror_type = ING_PORT_MIRROR`。
		- 在 `meta` 中记录 `mirror_header_type`、`mirror_header_info`、`ingress_port`、`mirror_session`。
		- 保存 `ingress_mac_tstamp` 和 `ingress_global_tstamp`，为后续 CPU 分析提供精确时间戳。
	- `acl_drop_and_mirror(MirrorId_t mirror_session)`：
		- 在镜像的同时调用 `drop()` 丢弃原始报文。

#### 4.4 RDMA ACL 和 OPCODE_DIGEST：识别 RDMA Write 流

- `rdma_acl` 表：
	- key 通常会匹配：
		- 源/目的 IP
		- UDP 端口（RoCEv2 默认 4791）
		- BTH `opcode` / `destinationQP` 等，用于筛选出特定的 RDMA 操作（如 RDMA Write）。
	- 动作集包括 `opcode_notify` 等。
- `action opcode_notify()`：
	- 将 `ig_dprsr_md.digest_type = OPCODE_DIGEST`。
	- 表示该报文包含我们感兴趣的 RDMA 信息，需要 IngressDeparser 生成 Telemetry Digest。

结合 Parser 中提取的 `opcode`、`destinationQP` 和 RETH 中的 `dmaLength`，数据面可以区分：

- RDMA Write 首包（例如 opcode = 0x06）。
- RDMA Write 尾包（例如 opcode = 0x09）。

配合控制平面的回调，即可计算每条 RDMA Write 流的首包与尾包时间差，得到 FCT。

#### 4.5 时间戳寄存器与时间差计算（概念说明）

在代码中还定义了若干 Register 与 RegisterAction，用于记录与更新每条 RDMA 流的时间戳：

- `rdma_first_pkt_reg`：记录每个流第一次出现时的相关计数或索引。
- `rdma_pkt_timestamp_low_reg` / `rdma_pkt_timestamp_high_reg`：
	- 将 48bit 的 `ingress_global_tstamp` 拆为低 32bit 与高 16bit 存储。
	- 后续报文到来时，计算与寄存器中时间戳的差值，得到 `timestamp_diff_1/2/3`，供 `TimeOutPipe` 使用。

实际培训时可以用伪代码说明：

- 第一次报文：将当前时间戳写入寄存器。
- 后续报文：从寄存器中读出前一时间戳，与当前时间戳做差，结果拆分为三个 16bit 存入 `timestamp_diff_1/2/3`。
- `time_out_pipe.apply()`：根据配置的 range 判断是否触发 TIMEOUT_DIGEST。

### 5. IngressDeparser：生成 Telemetry Digest 与镜像封装

IngressDeparser 的关键对象：

- `Digest<digest_t>() opcode_digest;`：用于上报 RDMA 相关的 Telemetry 信息。
- `Digest<time_out_digest_t>() time_out_digest;`：用于上报时间间隔超时事件。
- `Mirror() ing_port_mirror;`：用于真正执行镜像复制。
- `Checksum() ipv4_checksum;`：用于更新 IPv4 校验和。

`apply` 逻辑核心：

1. 根据 `ig_dprsr_md.digest_type` 判断：
	 - 若为 `OPCODE_DIGEST`：
		 - 将 `meta.src_address`、`meta.dst_address`、`meta.src_port`、`meta.dst_port`、`meta.opcode`、`meta.destinationQP`、`meta.dmaLength` 以及 `meta.ingress_global_tstamp` 打包到 `opcode_digest` 并发送给控制面。
	 - 若为 `TIMEOUT_DIGEST`：
		 - 将 `meta.timestamp_diff_1/2/3` 打包到 `time_out_digest` 并发送。
2. 若 `ig_dprsr_md.mirror_type == ING_PORT_MIRROR`：
	 - 调用 `ing_port_mirror`，在报文前附加内部镜像头部（`ing_port_mirror_h` 等）。
3. 更新 IPv4 校验和：
	 - 基于修改后的 IPv4 头字段重新计算 `hdr.ipv4.hdr_checksum`。
4. `pkt.emit(hdr);`：
	 - 输出包含 Bridge/Mirror/TCP/IP 等所有头部的报文，交给 Egress 管线进一步处理。

### 6. Egress：镜像报文到 CPU

Egress 管线的主要作用是：

1. 在 `EgressParser` 中解析内部头部：
	 - 通过 `inthdr_h` 的 `header_type` / `header_info` 决定是否解析 `bridge_h` 或 `ing_port_mirror_h`。
2. 在 `Egress` 控制中：
	 - `mirror_dest` 表根据镜像会话等信息决定：
		 - `just_send()`：按原路径转发。
		 - `send_to_cpu()`：构造发往 CPU 的报文：
			 - 置 `hdr.cpu_ethernet` valid，填入 `dst_addr`、`src_addr`、`ether_type = ETHERTYPE_TO_CPU`。
			 - 填充 `hdr.to_cpu` 头部：镜像会话号、入口端口、入口/出口时间戳、原始报文长度等。
3. 在 `EgressDeparser` 中：
	 - 统一 `pkt.emit(hdr);` 发出带 to_cpu 头部的报文。

CPU 端收到 to_cpu 报文后，可以结合 RDMA Telemetry Digest 进行更细粒度的分析，比如重传次数、路径时延抖动等。

## 控制平面实现（setup.py）

控制平面脚本位于 [Telemetry/setup.py](Telemetry/setup.py)，在 bfshell 的 Python 环境中运行。其主要职责：

- 建立基本的 IPv4 转发路径，让 RoCEv2 流量可以正常通过交换机。
- 配置随机丢包率，用于实验 RDMA 重传行为。
- 配置时间间隔阈值，触发 TIMEOUT_DIGEST。
- 注册 Telemetry Digest 回调，统计每条 RDMA Write 流的首/尾时间戳，并输出到文件。

### 1. 环境与表句柄获取

- 根据当前 PATH 自动推导 `SDE` 与 `SDE_INSTALL` 环境变量，并打印出来方便确认。
- 获取 P4 管线和模块：
	- `p4 = bfrt.mirror_digest.pipe`
	- `p4_learn = p4.IngressDeparser`
	- `p4_time_out_digest = p4.IngressDeparser.pipe.IngressDeparser`（指向 TimeOut Digest 所在的 IngressDeparser 实例）。
- 获取数据面中各种表的句柄：
	- `nexthop = p4.Ingress.nexthop`
	- `ipv4_host = p4.Ingress.ipv4_host`
	- `rdma_acl = p4.Ingress.rdma_acl`
	- `random_drop = p4.Ingress.random_drop`
	- `time_out_pkt = p4.Ingress.time_out_pipe.time_out_pkt`

### 2. 基本转发配置

- 为 `nexthop` 表添加两条出端口映射：
	- `nexthop_id=0 → port=144`
	- `nexthop_id=1 → port=128`
- 在 `ipv4_host` 表中配置目的 IP 对应的 nexthop：
	- 例如 `11.11.11.200 → nexthop=0`，`11.11.11.108 → nexthop=1`。

这样，当有 IP 报文（包括承载 RoCEv2 的报文）到达时，能够按配置的路径在交换机间转发。

### 3. 随机丢包率配置（random_drop）

脚本中示例：

- `rate = 0`，表示默认不丢包（`random_drop.add_with_set_drop` 被注释掉）。
- `random_value_end = int(65535 * rate)`：
	- 若 `rate = 0.01`，则 `random_value_end ≈ 655`，表示约 1% 报文会满足条件而被 `set_drop` 丢弃。

使用方式：

- 在实验时，可以根据需要修改 `rate` 并取消 `random_drop.add_with_set_drop(...)` 的注释：
	- 设置 `random_value_start=0`，`random_value_end` 为对应比例的阈值，从而控制全局丢包率。
- 丢包将触发 RDMA 协议重传，结合后续 Telemetry 统计，可以研究**丢包对 RDMA 流完成时间和性能的影响**。

### 4. 时间间隔阈值配置（time_out_pkt）

`time_out_pkt` 表用于配置触发 TIMEOUT_DIGEST 的时间间隔范围。

- 注释中给出示例：
	- 时间差以 48bit 表示：`timestamp_diff = (timestamp_diff_3 << 32) | (timestamp_diff_2 << 16) | timestamp_diff_1`。
	- 想要检测 1ms 左右的间隔：
		- `1ms = 0x0000 000F 4240`（十六进制表示）。
		- 由于 3 段 16bit 均要满足 range 匹配，因此舍弃最低 16bit 精度，使用 `0x0000 000F 0000`，约等于 0.98304ms。
- 脚本中的配置：
	- `timestamp_diff_1_start=0x0000, timestamp_diff_1_end=0xffff`（低 16bit 不限制）。
	- `timestamp_diff_2_start=0x3b9a, timestamp_diff_2_end=0xffff`。
	- `timestamp_diff_3_start=0x0000, timestamp_diff_3_end=0xffff`。

要点：

- 当某条 RDMA 流的相邻两个报文时间差落在上述范围内时，数据面会触发 TIMEOUT_DIGEST，上报一条“时间间隔异常”的事件，由 `time_out_digest_callback` 在控制面打印。

### 5. 流表结构与统计文件

脚本中通过 Python 字典 `flow_table` 维护每条 RDMA 流的状态：

- key：`(src_ip, dst_ip, src_port, dst_port, destinationQP)`。
- value：一个字典：
	- `"dmaLength"`：当前记录的 DMA 长度。
	- `"first_pkt_tstamp"`：记录首个 RDMA Write 报文的全局时间戳。
	- `"last_pkt_tstamp"`：记录最后一个 RDMA Write 报文的全局时间戳。

同时，脚本在 `/root/out_put_data/` 目录下创建一个带时间戳的 CSV 文件：

- 文件名示例：`flow_table_YYYYMMDD-HHMMSS.csv`。
- 首行表头：`src_ip,dst_ip,src_port,dst_port,destinationQP,dmaLength,first_pkt_tstamp,last_pkt_tstamp`。

在流完成后会将每条流的统计写入该文件，方便后续用 Python、R 或其他工具进行脱机分析。

### 6. RDMA Telemetry Digest 回调：my_learning_cb

`my_learning_cb` 用于处理来自数据面的 `OPCODE_DIGEST`：

1. 遍历 `msg` 中每一条 digest，提取字段：
	 - `src_ip`、`dst_ip`、`src_port`、`dst_port`、`opcode`。
	 - `global_tstamp = digest["ingress_global_tstamp"]`。
	 - `destinationQP`、`dmaLength`。
2. 构造 key：`(src_ip, dst_ip, src_port, dst_port, destinationQP)`。
3. 对不同 opcode 做不同处理：
	 - 若 key 不在 `flow_table` 且 `opcode == 0x06`（RDMA Write 首包）：
		 - 新建条目：
			 - `dmaLength = 当前报文的 dmaLength`。
			 - `first_pkt_tstamp = global_tstamp`。
			 - `last_pkt_tstamp = 0`（尚未结束）。
	 - 若 key 已在 `flow_table` 且 `opcode == 0x09`（RDMA Write 尾包）：
		 - 更新 `last_pkt_tstamp = global_tstamp`。
		 - 读取 `first_pkt_tstamp` 与 `dmaLength`，并检查两者是否非 0。
		 - 将一条记录写入 CSV 文件：
			 - `src_ip, dst_ip, src_port, dst_port, destinationQP, dmaLength, first_pkt_tstamp, last_pkt_tstamp`。
		 - 打印一行日志 `Flow {...} writed.`。
		 - `del flow_table[key]`，释放该流的内存。

通过 `last - first` 就可以在离线分析中计算**每条 RDMA Write 流的完成时间（FCT）**，并结合随机丢包、流量大小等因素进行性能研究。

### 7. TimeOut Digest 回调：time_out_digest_callback

`time_out_digest_callback` 用于处理来自数据面的 `TIMEOUT_DIGEST`：

1. 同样遍历 `msg` 中每条 digest，读取：
	 - `diff1 = digest["timestamp_diff_1"]`。
	 - `diff2 = digest["timestamp_diff_2"]`。
	 - `diff3 = digest["timestamp_diff_3"]`。
2. 组合为 48bit 时间差：
	 - `diff = (diff3 << 32) | (diff2 << 16) | diff1`。
3. 打印日志：
	 - 显示三段时间差及合成后的总时间差，便于在终端快速观测哪些流超过了设定的时间阈值。

这部分主要用于**实时监控出现大延迟/潜在超时的 RDMA 流**，可以与 FCT 统计结合使用。

### 8. 回调注册与清理

脚本最后一部分负责回调的注册：

- 在注册前，尝试：
	- `p4_learn.opcode_digest.callback_deregister()`。
	- `p4_time_out_digest.time_out_digest.callback_deregister()`。
	- 以清除旧的回调，避免重复触发。
- 然后注册新的回调：
	- `p4_learn.opcode_digest.callback_register(my_learning_cb)`。
	- `p4_time_out_digest.time_out_digest.callback_register(time_out_digest_callback)`。

终端会输出“Learning callback registered”，代表 Telemetry 回调配置生效。

## 培训讲解建议步骤

在为他人培训本 Telemetry 模块时，可以按以下顺序组织内容：

1. **总体目标与场景介绍**
	 - 说明：本例在可编程交换机上实现了针对 RoCEv2 RDMA Write 流的细粒度 Telemetry，包括 FCT 统计和超时检测，并可通过随机丢包研究重传行为。
2. **数据平面结构讲解（mirror_digest.p4）**
	 - 从基础头部到 RoCEv2 头部，解释 BTH/RETH、opcode、destinationQP、dmaLength 的含义。
	 - 讲解 IngressParser 的解析路径：以太网 → VLAN → IPv4 → UDP → RoCEv2。
	 - 重点说明 Ingress 中的：
		 - `rdma_acl` 如何识别 RDMA Write 并触发 OPCODE_DIGEST。
		 - 随机丢包 `random_drop` 如何利用 `Random<bit<16>>` 实现概率丢包。
		 - 时间戳寄存器与 `TimeOutPipe` 如何计算并匹配时间差，产生 TIMEOUT_DIGEST。
	 - 说明 IngressDeparser 如何打包 Telemetry Digest 和执行镜像封装。
3. **控制平面脚本讲解（setup.py）**
	 - 逐步解释环境变量设置、表句柄获取、基本转发配置。
	 - 讲解如何调整 `rate` 设置丢包率，以及如何设置 `time_out_pkt` 的时间阈值。
	 - 详细走读 `my_learning_cb` 和 `time_out_digest_callback`，让学员理解：
		 - 如何用 Digest 回调实现流级统计。
		 - CSV 文件中各字段的含义，以及如何离线计算 FCT 和重传情况。
4. **动手实验建议**
	 - 编译并加载 P4 程序：
		 - `$SDE/p4_build.sh mirror_digest.p4`
		 - `$SDE/run_switchd.sh -p mirror_digest`
	 - 配置端口（使用本 README 前半部分或 `port.txt` 脚本）。
	 - 运行 Telemetry 控制脚本：`$SDE/run_bfshell.sh -b setup.py -i`。
	 - 使用 [Telemetry/scapy_rocev2.py](Telemetry/scapy_rocev2.py) 或其他流量发生器，发送 RDMA Write 流量：
		 - 观察终端中的 TIMEOUT_DIGEST 打印。
		 - 查看 `/root/out_put_data/` 下的 CSV 文件，验证 FCT 统计是否符合预期。
	 - 修改 `rate` 提高丢包率，比较不同丢包条件下的 FCT 分布和可能的重传影响。
5. **扩展讨论**
	 - 如何：
		 - 增加更多 opcode 类型（如 Read、Write with Immediate）统计。
		 - 把寄存器扩展为真正的 Hash Table，支持较大规模流表。
		 - 将 TIMEOUT_DIGEST 与 FCT 统计结合，实现在线异常流检测与告警。

通过以上内容，学员可以系统地理解：**如何在可编程交换机上针对 RoCEv2 流量实现细粒度 Telemetry，从数据面解析到控制面统计的完整闭环。**
