#include <core.p4>
#include <tna.p4>



/*************************************************************************
 ************* C O N S T A N T S    A N D   T Y P E S  *******************
**************************************************************************/
const bit<16> ETHERTYPE_TPID   = 0x8100;
const bit<16> ETHERTYPE_IPV4   = 0x0800;
const bit<16> ETHERTYPE_TO_CPU = 0xBF01;
const bit<16> ETHRTYPER_ROCE   = 0x8915;
const bit<8>  IPv4_PROTO_TCP   = 0x06;
const bit<8>  IPv4_PROTO_UDP   = 0x11;
const bit<8>  IPv4_PROTO_ICMP  = 0x01;

const int NEXTHOP_ID_WIDTH = 14;
typedef bit<(NEXTHOP_ID_WIDTH)> nexthop_id_t;
typedef bit<32> iCRC_t;
typedef bit<32> remote_key_t;
typedef bit<24> queue_pair_t;
typedef bit<24> psn_t; // RoCEv2 中的数据包序列号 (Packet sequence number)
typedef bit<64> memory_address_t;   // 物理内存地址(共 2^64) 8bytes

const bit<3> OPCODE_DIGEST= 0x1;
const bit<3> TIMEOUT_DIGEST= 0x2;

/* Table Sizing */
const int IPV4_HOST_TABLE_SIZE = 131072;
const int IPV4_LPM_TABLE_SIZE  = 12288;

const int IPV6_HOST_TABLE_SIZE = 65536;
const int IPV6_LPM_TABLE_SIZE  = 4096;

const int NEXTHOP_TABLE_SIZE   = 1 << NEXTHOP_ID_WIDTH;

/*************************************************************************
 ***********************  H E A D E R S  *********************************
 *************************************************************************/

/*  Define all the headers the program will recognize             */
/*  The actual sets of headers processed by each gress can differ */

/* Standard ethernet header */
/* 14Bytes */
header ethernet_h {
    bit<48>   dst_addr;
    bit<48>   src_addr;
    bit<16>   ether_type;
}

header vlan_tag_h {
    bit<3>   pcp;
    bit<1>   cfi;
    bit<12>  vid;
    bit<16>  ether_type;
}
/* 20 Bytes */
header ipv4_h {
    bit<4>   version;
    bit<4>   ihl;
    bit<8>   diffserv;
    bit<16>  total_len;
    bit<16>  identification;
    bit<3>   flags;
    bit<13>  frag_offset;
    bit<8>   ttl;
    bit<8>   protocol;
    bit<16>  hdr_checksum;
    bit<32>  src_addr;
    bit<32>  dst_addr;
}

header ipv4_options_h {
    varbit<320> data;
}

header ipv6_h {
    bit<4>   version;
    bit<8>   traffic_class;
    bit<20>  flow_label;
    bit<16>  payload_len;
    bit<8>   next_hdr;
    bit<8>   hop_limit;
    bit<128> src_addr;
    bit<128> dst_addr;
}

/* 20 Bytes */
header tcp_h {
    bit<16>  src_port;
    bit<16>  dst_port;
    bit<32>  seq_no;
    bit<32>  ack_no;
    bit<4>   data_offset;
    bit<4>   res;
    bit<8>   flags;
    bit<16>  window;
    bit<16>  checksum;
    bit<16>  urgent_ptr;
}

/* 8 Bytes */
header udp_h {
    bit<16>  src_port;
    bit<16>  dst_port;
    bit<16>  len;
    bit<16>  checksum;
}

/*ICMP header*/
header icmp_h {
    bit<8>   type;
    bit<8>   code;
    bit<16>  checksum;
    bit<32>  rest_of_header;
}

// Base Transport Header (BTH) (12 Bytes)
header infiniband_bth_h{
	bit<8> opcode;
	bit<1> solicitedEvent;
	bit<1> migReq;
	bit<2> padCount;
	bit<4> transportHeaderVersion;
	bit<16> partitionKey;
	bit<8> reserved1;
	bit<24> destinationQP;
	bit<1> ackRequest;
	bit<7> reserved2;
	psn_t packetSequenceNumber; //bit<24>
}

// Atomic Extended Transport Header (ATOMIC_ETH) (28 bytes)
header infiniband_atomiceth_h{
	memory_address_t virtualAddress;
	bit<32> rKey;
	bit<64> data;
	bit<64> compare;
}

//RETH RDMA Extended Transport Header (RETH) (16 bytes)
header infiniband_reth_h{
    memory_address_t virtualAddress; //8 Bytes
    bit<32> rKey;      //4 Bytes
    bit<32> dmaLength; //4 Bytes
}

// iCRC 字段 (4 Bytes)
header infiniband_icrc_h{
	bit<32> iCRC;
}

/*** Internal Headers ***/

typedef bit<4> header_type_t; 
typedef bit<4> header_info_t; 

const header_type_t HEADER_TYPE_BRIDGE         = 0xB;
const header_type_t HEADER_TYPE_MIRROR_INGRESS = 0xC;
const header_type_t HEADER_TYPE_MIRROR_EGRESS  = 0xD;
const header_type_t HEADER_TYPE_RESUBMIT       = 0xA;

/* 
 * This is a common "preamble" header that must be present in all internal
 * headers. The only time you do not need it is when you know that you are
 * not going to have more than one internal header type ever
 */

#define INTERNAL_HEADER         \
    header_type_t header_type;  \
    header_info_t header_info


header inthdr_h {
    INTERNAL_HEADER;
}

/* Bridged metadata */
header bridge_h {
    INTERNAL_HEADER;
    
#ifdef FLEXIBLE_HEADERS
    @flexible    PortId_t  ingress_port;
#else
    bit<7> pad0; PortId_t ingress_port;
#endif


}

/* Ingress mirroring information */
const bit<3> ING_PORT_MIRROR = 0;  /* Choose between different mirror types */

header ing_port_mirror_h {
    INTERNAL_HEADER;
    
#ifdef FLEXIBLE_HEADERS    
    @flexible     PortId_t    ingress_port;
    @flexible     MirrorId_t  mirror_session;
    @flexible     bit<48>     ingress_mac_tstamp;
    @flexible     bit<48>     ingress_global_tstamp;
#else
    bit<7> pad0;  PortId_t    ingress_port;
    bit<6> pad1;  MirrorId_t  mirror_session;
                  bit<48>     ingress_mac_tstamp;
                  bit<48>     ingress_global_tstamp;    
#endif
}

/* 
 * Custom to-cpu header. This is not an internal header, but it contains 
 * the same information, because it is useful to the control plane
 * Note, that we cannot use @flexible annotation here, since these packets
 * do appear on the wire and thus must have deterministic header format
 */
header to_cpu_h {
    INTERNAL_HEADER;
    bit<6>    pad0; MirrorId_t  mirror_session;
    bit<7>    pad1; PortId_t    ingress_port;
                    bit<48>     ingress_mac_tstamp;
                    bit<48>     ingress_global_tstamp;
                    bit<48>     egress_global_tstamp;
                    bit<16>     pkt_length;
}


/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/
 
    /***********************  H E A D E R S  ************************/

struct my_ingress_headers_t {
    bridge_h           bridge;
    ethernet_h         ethernet;
    vlan_tag_h         vlan_tag;
    ipv4_h             ipv4;
    udp_h              udp;
    tcp_h              tcp;
    icmp_h             icmp;

    //ROCEv2 Header
    infiniband_bth_h   roce_bth;
    infiniband_reth_h  roce_reth;
}

    /******  G L O B A L   I N G R E S S   M E T A D A T A  *********/

struct my_ingress_metadata_t {
    header_type_t  mirror_header_type;
    header_info_t  mirror_header_info;
    PortId_t       ingress_port;
    MirrorId_t     mirror_session;
    bit<48>        ingress_mac_tstamp;
    bit<48>        ingress_global_tstamp;
    bit<1>         ipv4_csum_err;

    //NOTE: For digest 
    bit<32>        src_address;
    bit<32>        dst_address;
    bit<16>        src_port;
    bit<16>        dst_port;
    bit<8>         opcode;
    bit<24>        destinationQP;
    bit<32>        dmaLength;
    // time out flag
    bit<8>         time_out;

    bit<16>        timestamp_diff_1;
    bit<16>        timestamp_diff_2;
    bit<16>        timestamp_diff_3;
}

// 摘要信息
struct digest_t {
    bit<32> src_ip;
    bit<32> dst_ip;
    bit<16> src_port;
    bit<16> dst_port;
    bit<8>  opcode; 
    bit<48> ingress_global_tstamp;
    bit<24> destinationQP;
    bit<32> dmaLength; 
}

//time out digest 
struct time_out_digest_t {
   bit<16>      timestamp_diff_1;
   bit<16>      timestamp_diff_2;
   bit<16>      timestamp_diff_3;
}

    /***********************  P A R S E R  **************************/
parser IngressParser(packet_in        pkt,
    /* User */    
    out my_ingress_headers_t          hdr,
    out my_ingress_metadata_t         meta,
    /* Intrinsic */
    out ingress_intrinsic_metadata_t  ig_intr_md)
{
    Checksum() ipv4_checksum;
    
    /* This is a mandatory state, required by Tofino Architecture */
     state start {
        pkt.extract(ig_intr_md);
        pkt.advance(PORT_METADATA_SIZE);
        transition init_meta;
    }

    state init_meta {
        meta = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

        hdr.bridge.setValid();
        hdr.bridge.header_type  = HEADER_TYPE_BRIDGE;
        hdr.bridge.header_info  = 0;

#ifndef FLEXIBLE_HEADERS
        hdr.bridge.pad0 = 0;
#endif
        hdr.bridge.ingress_port = ig_intr_md.ingress_port; 
        
        transition parse_ethernet;
    }
    
    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            ETHERTYPE_TPID:  parse_vlan_tag;
            ETHERTYPE_IPV4:  parse_ipv4;
            default: accept;
        }
    }

    state parse_vlan_tag {
        pkt.extract(hdr.vlan_tag);
        transition select(hdr.vlan_tag.ether_type) {
            ETHERTYPE_IPV4:  parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        ipv4_checksum.add(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IPv4_PROTO_TCP: parse_tcp;
            IPv4_PROTO_UDP: parse_udp;
            IPv4_PROTO_ICMP: parse_icmp;
            default: accept;
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            4791: parse_rdma; // RoCEv2 默认端口号
            default: accept;
        }
    }

    state parse_icmp {
        pkt.extract(hdr.icmp);
        transition accept;
    }

    state parse_rdma {
        pkt.extract(hdr.roce_bth);
        transition select(hdr.roce_bth.opcode) {
            0x06: parse_reth;    //RDMA Write First
            default: accept;
        }
    }

    state parse_reth {
        pkt.extract(hdr.roce_reth);
        transition accept;
    }
}   

    /***************** M A T C H - A C T I O N  *********************/

control TimeOutPipe(inout my_ingress_metadata_t meta,
                    inout my_ingress_headers_t hdr,
                    in    ingress_intrinsic_metadata_from_parser_t   ig_prsr_md,
                    inout ingress_intrinsic_metadata_for_deparser_t  ig_dprsr_md)
{


    action set_time_out(){
        ig_dprsr_md.digest_type = TIMEOUT_DIGEST;
    }

    //NOTE time_out table
    table time_out_pkt{
        key = {
            meta.timestamp_diff_1 : range;
            meta.timestamp_diff_2 : range;
            meta.timestamp_diff_3 : range;
        }
        actions = {
            set_time_out; NoAction;
        }
        size = 1;
        default_action = NoAction();
    }

    apply {
        time_out_pkt.apply();
    }
}

control Ingress(
    /* User */
    inout my_ingress_headers_t                       hdr,
    inout my_ingress_metadata_t                      meta,
    /* Intrinsic */
    in    ingress_intrinsic_metadata_t               ig_intr_md,
    in    ingress_intrinsic_metadata_from_parser_t   ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t  ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t        ig_tm_md)
{
    nexthop_id_t    nexthop_id = 0;
    bit<8>          ttl_dec = 0;
    Random<bit<16>>()    random_gen;
    bit<16>         random_value = random_gen.get();
    TimeOutPipe()   time_out_pipe;

    
    
    action set_nexthop(nexthop_id_t nexthop) {
        nexthop_id = nexthop;
    }
    
    table ipv4_host {
        key = { hdr.ipv4.dst_addr : exact; }
        actions = {
            set_nexthop;
            @defaultonly NoAction;
        }
        const default_action = NoAction();
        size = IPV4_HOST_TABLE_SIZE;
    }

    table ipv4_lpm {
        key     = { hdr.ipv4.dst_addr : lpm; }
        actions = { set_nexthop; }
        
        default_action = set_nexthop(0);
        size           = IPV4_LPM_TABLE_SIZE;
    }


    /*********** NEXTHOP ************/
    action send(PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
    }

    action drop() {
        ig_dprsr_md.drop_ctl = 1;
    }

    action l3_switch(PortId_t port, bit<48> new_mac_da, bit<48> new_mac_sa) {
        hdr.ethernet.dst_addr = new_mac_da;
        hdr.ethernet.src_addr = new_mac_sa;
        ttl_dec = 1;
        send(port); 
    }

    table nexthop {
        key = { nexthop_id : exact; }
        actions = { send; drop; l3_switch; }
        size = NEXTHOP_TABLE_SIZE;
    }

    //NOTE: random drop pkt, threshold: 0~65535
    /***********Probabilistic drop pkt*************/
    action set_drop(){
        ig_dprsr_md.drop_ctl = 1;
    }
    action clear_drop(){
        ig_dprsr_md.drop_ctl = 0;
    }
    //NOTE 使用random 对pkt 进行随机丢包
    table random_drop{
        key = {
            random_value : range;
        }
        actions = {
            set_drop; clear_drop; NoAction;
        }
        size = 1;
        default_action = NoAction();
    }

    /********* MIRRORING ************/
    action acl_mirror(MirrorId_t mirror_session) {
        ig_dprsr_md.mirror_type = ING_PORT_MIRROR;

        meta.mirror_header_type = HEADER_TYPE_MIRROR_INGRESS;
        meta.mirror_header_info = (header_info_t)ING_PORT_MIRROR;

        meta.ingress_port   = ig_intr_md.ingress_port;
        meta.mirror_session = mirror_session;
        
        meta.ingress_mac_tstamp    = ig_intr_md.ingress_mac_tstamp;
        meta.ingress_global_tstamp = ig_prsr_md.global_tstamp;
    }

    action acl_drop_and_mirror(MirrorId_t mirror_session) {
        acl_mirror(mirror_session);
        drop();
    }
    
    table port_acl {
        key = {
            ig_intr_md.ingress_port : ternary;
        }
        actions = {
            acl_mirror; acl_drop_and_mirror; drop; NoAction;
        }
        size = 512;
        default_action = NoAction();
    }

    //NOTE rdma write pkt capture
    action opcode_notify() {
        ig_dprsr_md.digest_type = OPCODE_DIGEST;
    }

    table rdma_acl {
        key = {
            hdr.roce_bth.opcode : exact;
        }
        actions = {
            opcode_notify; acl_mirror; acl_drop_and_mirror; drop; NoAction;
        }
        const entries = {
            0x06 : opcode_notify(); //RDMA Write first pkt
            0x09 : opcode_notify(); //RDMA Write last pkt
        }
        size = 256;
        default_action = NoAction();
    }

    //NOTE: rdma_first_pkt_counter
    Register<bit<32>, bit<4>>(16) rdma_first_pkt_reg;
    RegisterAction<bit<32>, bit<4>, bit<32>>(rdma_first_pkt_reg) inc_rdma_first_pkt_counter = {
        void apply(inout bit<32> reg_data, out bit<32> result){
            result = reg_data;
            reg_data = reg_data |+| 1;
        }
    };
    //NOTE: rdma_pkt timestamp reg - 使用两个32位寄存器存储48位时间戳
    // 存储时间戳低32位
    Register<bit<32>, bit<16>>(0xFFFF) rdma_pkt_timestamp_low_reg;
    RegisterAction<bit<32>, bit<16>, bit<32>>(rdma_pkt_timestamp_low_reg) update_rdma_pkt_timestamp_low = {
        void apply(inout bit<32> reg_data, out bit<32> result){
            result = reg_data;  // 返回旧值
            reg_data = (bit<32>)ig_prsr_md.global_tstamp;  // 存储低32位
        }
    };
    
    // 存储时间戳高16位 - 使用预计算的值 高16位存在reg_data 高16位中
    Register<bit<32>, bit<16>>(0xFFFF) rdma_pkt_timestamp_high_reg;
    RegisterAction<bit<32>, bit<16>, bit<32>>(rdma_pkt_timestamp_high_reg) update_rdma_pkt_timestamp_high = {
        void apply(inout bit<32> reg_data, out bit<32> result){
            result = reg_data;  // 返回旧值
            bit<32> high_32 = (bit<32>)(ig_prsr_md.global_tstamp >> 16);
            reg_data = high_32 & 0xFFFF0000; // 保留高16位，低16位置0
        }
    };



    // NOTE: 没有使用 Hash table, 9bit 512个entrys, 后续可以拓展二次hash 避免碰撞
    // CRCPolynomial<bit<32>>(0x04C11DB7,false,false,false,32w0xFFFFFFFF,32w0xFFFFFFFF) crc32a;
    // Hash<bit<9>>(HashAlgorithm_t.CUSTOM,crc32a) hash_1;

    /*************time_out_action********/
    // action set_time_out(){
    //     meta.time_out = 1;
    //     ig_dprsr_md.digest_type = TIMEOUT_DIGEST;
    // }
    // //NOTE time_out table
    // table time_out_pkt{
    //     key = {
    //         timestamp_diff_1 : range;
    //         timestamp_diff_2 : range;
    //         timestamp_diff_3 : range;
    //     }
    //     actions = {
    //         set_time_out; NoAction;
    //     }
    //     size = 1;
    //     default_action = NoAction();
    // }


    
    apply {
        if (ig_prsr_md.parser_err == 0) {
            // random drop pkt
            random_drop.apply();
            if(ig_dprsr_md.drop_ctl == 0){
                if (hdr.ipv4.isValid()) {
                    // For digest
                    meta.src_address = hdr.ipv4.src_addr;
                    meta.dst_address = hdr.ipv4.dst_addr;
                    if (hdr.tcp.isValid()) {
                        meta.src_port = hdr.tcp.src_port;
                        meta.dst_port = hdr.tcp.dst_port;
                    } else if (hdr.udp.isValid()) {
                        meta.src_port = hdr.udp.src_port;
                        meta.dst_port = hdr.udp.dst_port;
                    } else {
                        meta.src_port = 0;
                        meta.dst_port = 0;
                    }
                    if(hdr.roce_bth.isValid()){
                        //digest message
                        meta.opcode = hdr.roce_bth.opcode;
                        meta.destinationQP = hdr.roce_bth.destinationQP;
                        //NOTE first_pkt_conter
                        if(hdr.roce_bth.opcode==0x06){
                            inc_rdma_first_pkt_counter.execute(0);
                        }else if(hdr.roce_bth.opcode==0x07){
                            inc_rdma_first_pkt_counter.execute(1);
                        }else if(hdr.roce_bth.opcode==0x09){
                            inc_rdma_first_pkt_counter.execute(2);                        
                        }

                        //NOTE update timestamp reg
                        bit<16> Qp_index = (bit<16>)(hdr.roce_bth.destinationQP & 0x00FFFF);
                        bit<32> old_low = update_rdma_pkt_timestamp_low.execute(Qp_index);
                        bit<32> old_high = update_rdma_pkt_timestamp_high.execute(Qp_index);
                        if(old_low != 0 && old_high != 0){ //跳过第一次读取旧值时为0的情况
                            // old time stamp
                            bit<48> old_time_stamp_48 = ((bit<48>)old_high << 16) | (bit<48>)old_low;
                            bit<64> old_time_stamp = (bit<64>)old_time_stamp_48;
                            bit<64> temp_global_tstamp = (bit<64>)ig_prsr_md.global_tstamp;
                            bit<64> timestamp_diff = (temp_global_tstamp - old_time_stamp);
                            //time_out table
                            bit<48> timestamp_diff_48 = (bit<48>)timestamp_diff;
                            meta.timestamp_diff_1 = (bit<16>)timestamp_diff_48;
                            meta.timestamp_diff_2 = (bit<16>)(timestamp_diff_48 >> 16);
                            meta.timestamp_diff_3 = (bit<16>)(timestamp_diff_48 >> 32);
                            //time_out_pkt.apply();
                            
                        }

                        if(hdr.roce_reth.isValid()){
                            meta.dmaLength = hdr.roce_reth.dmaLength;
                        } else {
                            meta.dmaLength = 0xFFFFFFFF;//表示无效;
                        }
                    } else {
                        meta.opcode = 0;
                        meta.destinationQP = 0;
                        meta.dmaLength = 0xFFFFFFFF;//表示无效;
                    }   

                    meta.ingress_global_tstamp = ig_prsr_md.global_tstamp;
                    rdma_acl.apply();
                    if (meta.ipv4_csum_err == 0 && hdr.ipv4.ttl > 1) {
                        if (!ipv4_host.apply().hit) {
                            ipv4_lpm.apply();
                        }
                        nexthop.apply();
                    }
                }

                if (hdr.ipv4.isValid()) {
                    hdr.ipv4.ttl =  hdr.ipv4.ttl - ttl_dec;
                }
                //time_out table  
                if(hdr.roce_bth.opcode != 0x06){ // 当不是rdma write first pkt 时，进行time_out table 匹配
                    time_out_pipe.apply(meta, hdr, ig_prsr_md, ig_dprsr_md);
                }
            }
        }  

        /* Mirroring */
        port_acl.apply();
    }
    
}

    /*********************  D E P A R S E R  ************************/
control IngressDeparser(packet_out pkt,
    /* User */
    inout my_ingress_headers_t                       hdr,
    in    my_ingress_metadata_t                      meta,
    /* Intrinsic */
    in    ingress_intrinsic_metadata_for_deparser_t  ig_dprsr_md)
{
    Checksum() ipv4_checksum; 
    Mirror()   ing_port_mirror;
    Digest<digest_t>() opcode_digest;
    Digest<time_out_digest_t>() time_out_digest;

    apply {
        //NOTE: for digest 
        if(ig_dprsr_md.digest_type == OPCODE_DIGEST){
            opcode_digest.pack({
                meta.src_address,
                meta.dst_address,
                meta.src_port,
                meta.dst_port,
                meta.opcode,
                meta.ingress_global_tstamp,
                meta.destinationQP,
                meta.dmaLength
            });   
        }else if(ig_dprsr_md.digest_type == TIMEOUT_DIGEST){
            
            time_out_digest.pack({
                meta.timestamp_diff_1,
                meta.timestamp_diff_2,
                meta.timestamp_diff_3
            });
        }
        /* 
         * If there is a mirror request, create a clone. 
         * Note: Mirror() externs emits the provided header, but also
         * appends the ORIGINAL ingress packet after those
         */
        if (ig_dprsr_md.mirror_type == ING_PORT_MIRROR) {
            ing_port_mirror.emit<ing_port_mirror_h>(
                meta.mirror_session,
                {
                    meta.mirror_header_type, meta.mirror_header_info,
#ifndef FLEXIBLE_HEADERS
                    0, /* pad0 */
#endif
                    meta.ingress_port,
#ifndef FLEXIBLE_HEADERS
                    0, /* pad1 */
#endif
                    meta.mirror_session,
                    meta.ingress_mac_tstamp, meta.ingress_global_tstamp
                });
        }

        /* Update the IPv4 checksum first. Why not in the egress deparser? */
        hdr.ipv4.hdr_checksum = ipv4_checksum.update({
                hdr.ipv4.version,
                hdr.ipv4.ihl,
                hdr.ipv4.diffserv,
                hdr.ipv4.total_len,
                hdr.ipv4.identification,
                hdr.ipv4.flags,
                hdr.ipv4.frag_offset,
                hdr.ipv4.ttl,
                hdr.ipv4.protocol,
                hdr.ipv4.src_addr,
                hdr.ipv4.dst_addr
            });
        /* Deparse the regular packet with bridge metadata header prepended */
        pkt.emit(hdr);
    }
}


/*************************************************************************
 ****************  E G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/

    /***********************  H E A D E R S  ************************/

struct my_egress_headers_t {
    ethernet_h   cpu_ethernet;
    to_cpu_h     to_cpu;
}

    /********  G L O B A L   E G R E S S   M E T A D A T A  *********/

struct my_egress_metadata_t {
    bridge_h           bridge;
    ing_port_mirror_h  ing_port_mirror;
}

    /***********************  P A R S E R  **************************/

parser EgressParser(packet_in        pkt,
    /* User */
    out my_egress_headers_t          hdr,
    out my_egress_metadata_t         meta,
    /* Intrinsic */
    out egress_intrinsic_metadata_t  eg_intr_md)
{
    inthdr_h inthdr;
    
    /* This is a mandatory state, required by Tofino Architecture */
    state start {
        pkt.extract(eg_intr_md);
        inthdr = pkt.lookahead<inthdr_h>();
           
        transition select(inthdr.header_type, inthdr.header_info) {
            ( HEADER_TYPE_BRIDGE,         _ ) :
                           parse_bridge;
            ( HEADER_TYPE_MIRROR_INGRESS, (header_info_t)ING_PORT_MIRROR ):
                           parse_ing_port_mirror;
            default : reject;
        }
    }

    state parse_bridge {
        pkt.extract(meta.bridge);
        transition accept;
    }

    state parse_ing_port_mirror {
        pkt.extract(meta.ing_port_mirror);
        transition accept;
    }
}

    /***************** M A T C H - A C T I O N  *********************/

control Egress(
    /* User */
    inout my_egress_headers_t                          hdr,
    inout my_egress_metadata_t                         meta,
    /* Intrinsic */    
    in    egress_intrinsic_metadata_t                  eg_intr_md,
    in    egress_intrinsic_metadata_from_parser_t      eg_prsr_md,
    inout egress_intrinsic_metadata_for_deparser_t     eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_port_t  eg_oport_md)
{
    action just_send() {}

    action send_to_cpu() {
        hdr.cpu_ethernet.setValid();
        hdr.cpu_ethernet.dst_addr   = 0xFFFFFFFFFFFF;
        hdr.cpu_ethernet.src_addr   = 0xAAAAAAAAAAAA;
        hdr.cpu_ethernet.ether_type = ETHERTYPE_TO_CPU;

        hdr.to_cpu.setValid();
        hdr.to_cpu.header_type = meta.ing_port_mirror.header_type;
        hdr.to_cpu.header_info = meta.ing_port_mirror.header_info;
        hdr.to_cpu.pad0 = 0;
        hdr.to_cpu.pad1 = 0;
        hdr.to_cpu.mirror_session  = meta.ing_port_mirror.mirror_session;
        hdr.to_cpu.ingress_port    = meta.ing_port_mirror.ingress_port;

        /* Packet length adjustement since it had headers prepended */
        hdr.to_cpu.pkt_length      = eg_intr_md.pkt_length -
                                   (bit<16>)sizeInBytes(meta.ing_port_mirror);

        /* Timestamps */
        hdr.to_cpu.ingress_mac_tstamp    = meta.ing_port_mirror.
                                                    ingress_mac_tstamp;
        hdr.to_cpu.ingress_global_tstamp = meta.ing_port_mirror.
                                                    ingress_global_tstamp;
        hdr.to_cpu.egress_global_tstamp  = eg_prsr_md.global_tstamp; 
    }

    table mirror_dest {
        key = {
            meta.ing_port_mirror.mirror_session : exact;
        }
        
        actions = {
            just_send;
            send_to_cpu;
        }
        default_action = just_send();
    }
    
    apply {
        if (meta.ing_port_mirror.isValid()) {
            mirror_dest.apply();
        }
    }
}

    /*********************  D E P A R S E R  ************************/

control EgressDeparser(packet_out pkt,
    /* User */
    inout my_egress_headers_t                       hdr,
    in    my_egress_metadata_t                      meta,
    /* Intrinsic */
    in    egress_intrinsic_metadata_for_deparser_t  eg_dprsr_md)
{
    apply {
        pkt.emit(hdr);
    }
}


/************ F I N A L   P A C K A G E ******************************/
Pipeline(
    IngressParser(),
    Ingress(),
    IngressDeparser(),
    EgressParser(),
    Egress(),
    EgressDeparser()
) pipe;

Switch(pipe) main;

