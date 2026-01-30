# ECMP

本目录包含基于 P4 的等价多路径转发（ECMP）数据平面示例，核心代码在 [ECMP/ecmp.p4](ECMP/ecmp.p4)。本节面向培训场景，详细介绍该 P4 程序的实现思路和关键逻辑，便于讲解和扩展。

## 功能概述

该程序基于 Tofino TNA 架构，实现了：

- IPv4 流量的二层/三层转发出口选择；
- 使用哈希实现的 **二路 ECMP 负载均衡**（通过 1bit 哈希值在两条路径间选择）；
- IPv4 头部校验和重计算；
- ARP 报文的单播转发（带 `bypass_egress`，绕过 Egress 管线）。

（控制面示例未包含在本目录中，需要通过 bfshell/bfrt 自行下发表项。）

## 数据平面总体结构

ecmp.p4 采用标准 TNA 管线结构：

- IngressParser：解析以太网 / VLAN / ARP / IPv4 / ICMP / IGMP / TCP / UDP；
- Ingress：
	- 对 IPv4 业务流进行哈希，算出 1bit 的 ECMP 选择值；
	- 根据 (dst_ip, ecmp) 查表得到实际出口端口，实现负载均衡；
	- 对 ARP 报文查表决定出口端口，并可绕过 Egress；
- IngressDeparser：重算 IPv4 头部校验和并发包；
- EgressParser / Egress / EgressDeparser：当前不做任何修改，仅作占位和透传。

## 1. 头部与元数据结构

### 1.1 基本头部定义

程序定义了常见二三四层头部：

- `ethernet_h`
	- `dst_addr`、`src_addr`、`ether_type`；
	- `ether_type` 使用枚举 `ether_type_t`：`TPID(0x8100)`、`IPV4(0x0800)`、`ARP(0x0806)`。
- `vlan_tag_h`
	- 支持 VLAN Tag（PCP、CFI、VID）以及后续的 `ether_type`，用于解析 VLAN 堆叠。
- `arp_h`
	- 标准 ARP 头部字段，包含源/目的 MAC 与 IPv4 地址。
- `ipv4_h`
	- 标准 IPv4 头部，包含 `protocol`、`src_addr`、`dst_addr` 等，用于后续 ECMP 哈希和匹配。
- `icmp_h` / `igmp_h` / `tcp_h` / `udp_h`
	- 四层头部定义，便于提取端口或其它控制信息。

### 1.2 Ingress 头部与元数据封装

- `my_ingress_headers_t`
	- 包含：`ethernet`、`arp`、`vlan_tag[2]`、`ipv4`、`icmp`、`igmp`、`tcp`、`udp`；
	- 其中 `vlan_tag` 为长度 2 的数组，可解析最多两层 VLAN。
- `my_ingress_metadata_t`
	- 当前仅有一个字段 `ll : bit<32>`；
	- 通过 `pkt.lookahead<bit<32>>()` 从 L4 负载前 4 字节中取值，用作哈希输入之一，以提升 ECMP 的流级均衡效果。

## 2. IngressParser：协议解析流程

IngressParser 负责从包中提取各层头部和部分元数据，状态机大致如下：

1. `state start`
	 - 提取 `ingress_intrinsic_metadata_t ig_intr_md`（硬件内建元数据，例如入口端口）；
	 - `pkt.advance(PORT_METADATA_SIZE)` 跳过端口元数据区域；
	 - 转入 `meta_init`。
2. `state meta_init`
	 - 当前实现中仅负责状态跳转，无额外初始化；
	 - 直接跳转 `parse_ethernet`。
3. `state parse_ethernet`
	 - 提取 `hdr.ethernet`；
	 - 根据 `ether_type` 选择不同解析路径：
		 - VLAN：`TPID &&& 0xEFFF` → `parse_vlan_tag`；
		 - IPv4：`IPV4` → `parse_ipv4`；
		 - ARP：`ARP` → `parse_arp`；
		 - 其他：`accept`（不再深入解析）。
4. `state parse_arp`
	 - 提取 `hdr.arp` 后 `accept`；
	 - 后续在 Ingress 中根据 ARP 目的 IP 做单播转发。
5. `state parse_vlan_tag`
	 - 连续提取 VLAN Tag：`hdr.vlan_tag.next`；
	 - 若 `last.ether_type` 仍为 TPID，则继续解析下一层 VLAN；
	 - 若为 IPv4，则跳转 `parse_ipv4`；否则 `accept`。
6. `state parse_ipv4`
	 - 提取 `hdr.ipv4`；
	 - 根据 `protocol` 字段选择：
		 - `1` → `parse_icmp`；
		 - `2` → `parse_igmp`；
		 - `6` → `parse_tcp`；
		 - `17` → `parse_udp`；
		 - 其他 → `accept`。
7. `state parse_icmp / parse_igmp / parse_tcp / parse_udp`
	 - 在提取对应 L4 头部前，都执行：
		 - `meta.ll = pkt.lookahead<bit<32>>();`
		 - 这一步从 L4 头之后的负载开头“偷看”4 字节，作为哈希的附加维度，增强不同流之间的区分度；
	 - 然后 `pkt.extract(hdr.xxx)` 并 `transition accept`。

培训讲解要点：

- 解析器只做“分层解析 + 提取关键字段”，为后续 Ingress 控制里的 ECMP 哈希和匹配提供数据支撑；
- 使用 `lookahead` 而不是 `extract`，是为了不改变后续头部解析的位置，同时多取一点 payload 信息进入哈希，使不同应用流更均匀分布到多路径上。

## 3. Ingress 控制逻辑：ECMP 负载均衡与 ARP 处理

Ingress 控制块是该程序的核心，主要包括：

- 多个 CRC 多项式与 Hash 对象的定义；
- ECMP 哈希计算（计算 1bit 的路径选择值）；
- 根据 (dst_ip, ecmp) 选择出口端口的表 `ecmp_select_t`；
- ARP 报文处理表 `arp_host`。

### 3.1 哈希对象与 ECMP 决策

首先定义了多种 CRC 多项式和 Hash 对象，其中与 ECMP 直接相关的是：

- `CRCPolynomial<bit<32>>(0x04C11DB7, ...) crc32a;`
- `Hash<bit<1>>(HashAlgorithm_t.CUSTOM, crc32c) hash_ecmp;`

程序内部有多个 `Hash<bit<9>>` / `Hash<bit<14>>` 对象预留给更复杂的场景，但当前 ECMP 实际只使用 `hash_ecmp`：

- `bit<1> ecmp = 0;`
- `action cal_ecmp()`：
	- `ecmp = hash_ecmp.get({hdr.ipv4.src_addr, hdr.ipv4.dst_addr, meta.ll, hdr.ipv4.protocol});`
	- 即将 IPv4 源地址、目的地址、元数据 `ll`（来自 L4 payload）、IPv4 协议号一并作为哈希输入；
	- 输出为 1bit（0 或 1），表示在两条等价路径间二选一。
- `@stage(0) table cal_ecmp_t`
	- 无 key，仅有 `cal_ecmp` 一个动作；
	- `default_action = cal_ecmp;`，即每个 IPv4 报文都会自动计算一次 ECMP 哈希值。

随后根据 `ecmp` 选择具体端口：

- `action ecmp_select(PortId_t port)`：
	- 将 `ig_tm_md.ucast_egress_port = port`，决定该报文的单播出口端口；
	- 将 `hdr.ipv4.ttl = hdr.ipv4.ttl;`（保持 TTL 不变，本示例未做 TTL 递减）。
- `@stage(1) table ecmp_select_t`
	- key：
		- `hdr.ipv4.dst_addr : exact`；
		- `ecmp : exact`；
	- actions：仅 `ecmp_select`；
	- `default_action = ecmp_select(0);`，默认出口端口为 0；
	- `size = 100`，可配置最多 100 个目的 IP 的 ECMP 条目。

控制面使用方式（概念上）：

- 对每个目的 IP，可配置两条表项：
	- `(dst_ip = X, ecmp = 0) → port = P0`；
	- `(dst_ip = X, ecmp = 1) → port = P1`；
- 当报文到达时：
	- `cal_ecmp_t` 基于四元组+payload 片段计算出 `ecmp`；
	- `ecmp_select_t` 根据 `(dst_ip, ecmp)` 查表，得到对应的物理出口端口；
	- 从而在多条等价路径间实现负载均衡。

在培训中可以强调：

- 这是一个 **简单二路 ECMP 示例**，但通过调整哈希输入，可以较好地做到“流级均衡”；
- 若需要更多路径，可以把 `bit<1> ecmp` 扩展成更宽的 hash 值，例如 `bit<2>`、`bit<3>`，并相应扩展表的 key 与控制面配置。

### 3.2 ARP 报文处理与 bypass_egress

对于 ARP 报文，程序使用独立表 `arp_host` 进行处理：

- `action unicast_send(PortId_t port)`
	- 设置 `ig_tm_md.ucast_egress_port = port`；
	- 设置 `ig_tm_md.bypass_egress = 1;`，表示绕过 Egress 管线直接发出；
	- 适合对简单的 ARP 请求/应答直接在 Ingress 完成转发，提高效率。
- `action drop()`：
	- 设置 `ig_dprsr_md.drop_ctl = 1`，丢弃报文。
- `@stage(0) table arp_host`
	- key：`hdr.arp.proto_dst_addr : exact`；
	- actions：`unicast_send; drop;`；
	- `default_action = drop();`，未命中条目时 ARP 报文会被丢弃。

Ingress `apply` 中的处理顺序：

```text
if (hdr.arp.isValid()) {
		arp_host.apply();
} else if (hdr.ipv4.isValid()) {
		cal_ecmp_t.apply();
		ecmp_select_t.apply();
}
```

- 优先处理 ARP 报文；
- 对 IPv4 报文执行 ECMP 哈希与下一跳选择；
- 对其他类型报文不做任何处理（未设置出口端口，设备将按默认行为处理）。

## 4. IngressDeparser：IPv4 校验和更新

IngressDeparser 的作用是：

- 如果 `hdr.ipv4.isValid()`：
	- 使用 `Checksum() ipv4_checksum;` 对 IPv4 头字段（版本、IHL、DiffServ、Total Length、ID、Flags、Fragment Offset、TTL、Protocol、源/目的 IP）重新计算校验和；
	- 更新 `hdr.ipv4.hdr_checksum`；
- 最终 `pkt.emit(hdr);` 发出完整的头部堆栈。

由于 ECMP 逻辑当前未修改 IPv4 头部除 TTL 外的字段（且 TTL 也被保持不变），这个示例中校验和更新主要是演示如何在 Deparser 中进行协议级处理；在实际项目中如果修改 TTL 或其他 IPv4 字段，这一步是必须的。

## 5. Egress 管线

Egress 部分实现非常简单：

- `EgressParser`：只提取 `eg_intr_md` 后直接 `accept`；
- `Egress` 控制：`apply` 中没有任何逻辑，报文不被修改；
- `EgressDeparser`：直接 `pkt.emit(hdr);` 输出头部。

这说明本示例所有实际业务逻辑（ECMP/ARP）均在 Ingress 管线完成，Egress 仅用于占位和保持架构完整。

## 培训讲解建议流程

在对他人培训该 ECMP 示例时，可以按以下顺序组织内容：

1. **整体目标与场景**
	 - 介绍 ECMP 的概念：多条等价路径之间按流负载均衡；
	 - 说明本示例实现的是“二路 ECMP + ARP 处理”，并强调仅数据平面，控制面需学员自行编写。
2. **头部与解析器讲解**
	 - 从以太网 / VLAN / ARP / IPv4 / L4 头部依次讲解，帮助学员熟悉 P4 中的头部定义方式；
	 - 重点解释 `pkt.lookahead<bit<32>>()` 的用途，以及为何要把 L4 payload 的一部分加入哈希输入。
3. **Ingress 控制与 ECMP 哈希**
	 - 讲解哈希多项式与 `Hash` 对象的定义方式；
	 - 详细走读 `cal_ecmp` 与 `ecmp_select_t` 的交互流程，让学员理解：
		 - 如何从五元组 + payload 计算哈希；
		 - 如何将 1bit 哈希结果映射到具体出口端口；
	 - 讨论如何扩展为 4 路、8 路 ECMP（增加哈希位宽、扩展表 key 和控制面逻辑）。
4. **ARP 处理逻辑**
	 - 介绍 `arp_host` 表和 `unicast_send` 动作；
	 - 说明 `bypass_egress` 的作用：为何有些简单报文可以只在 Ingress 完成处理。
5. **Deparser 与校验和**
	 - 简要说明 IPv4 校验和更新的流程和必要性；
	 - 强调 Deparser 可以做的不只是 emit，还能做协议一致性处理。
6. **动手实验建议**
	 - 引导学员：
		 - 编译并加载 ecmp.p4；
		 - 在 bfshell / bfrt 中：
			 - 为不同目的 IP 配置 `(dst_ip, ecmp)` → port 的映射；
			 - 为 ARP 请求配置 `arp_host` 表项；
		 - 用多条 TCP/UDP 流访问同一目的 IP，观察在各路径上的流量分布是否均衡；
	 - 鼓励学员调整哈希输入（例如加入 L4 端口）、修改哈希位宽，比较负载均衡效果。

通过以上结构化讲解，学员可以系统理解：如何在 P4 中利用哈希和表匹配实现 ECMP 负载均衡，以及如何在 Ingress 中同时处理 ARP 和 IPv4 业务流。
