#!/usr/bin/env python
# -*- coding: utf-8 -*-

from scapy.all import Ether, IP, UDP, Raw, sendp, get_if_hwaddr, get_if_addr
import struct,time

def build_bth(opcode, psn, dst_qp, ack_req=0, pad_cnt=0, tver=0, p_key=0xFFFF, solicited_event=0, mig_req=0):
    """
    构造一个 12 字节的 BTH (Base Transport Header)
    按照 P4 header infiniband_bth_h 的字段顺序构造:
    - bit<8> opcode
    - bit<1> solicitedEvent  
    - bit<1> migReq
    - bit<2> padCount
    - bit<4> transportHeaderVersion
    - bit<16> partitionKey
    - bit<8> reserved1
    - bit<24> destinationQP
    - bit<1> ackRequest
    - bit<7> reserved2
    - bit<24> packetSequenceNumber
    """
    bth_bytes = b''
    
    # Byte 0: opcode (8 bits)
    bth_bytes += struct.pack(">B", opcode & 0xFF)
    
    # Byte 1: solicitedEvent(1) + migReq(1) + padCount(2) + transportHeaderVersion(4)
    byte1 = ((solicited_event & 0x1) << 7) | ((mig_req & 0x1) << 6) | ((pad_cnt & 0x3) << 4) | (tver & 0xF)
    bth_bytes += struct.pack(">B", byte1)
    
    # Byte 2-3: partitionKey (16 bits)
    bth_bytes += struct.pack(">H", p_key & 0xFFFF)
    
    # Byte 4: reserved1 (8 bits)
    bth_bytes += struct.pack(">B", 0x00)
    
    # Byte 5-7: destinationQP (24 bits) 
    bth_bytes += struct.pack(">I", dst_qp & 0xFFFFFF)[1:]  # 取低 3 字节
    
    # Byte 8: ackRequest(1) + reserved2(7)
    byte8 = ((ack_req & 0x1) << 7) | (0x00 & 0x7F)  # reserved2 = 0
    bth_bytes += struct.pack(">B", byte8)
    
    # Byte 9-11: packetSequenceNumber (24 bits)
    bth_bytes += struct.pack(">I", psn & 0xFFFFFF)[1:]  # 取低 3 字节

    assert len(bth_bytes) == 12, f"BTH length should be 12 bytes, got {len(bth_bytes)}"
    return bth_bytes


def build_reth(virtual_addr=0x1234567890ABCDEF, rkey=0x98765432, dma_length=1024):
    """
    构造 16 字节的 RETH (RDMA Extended Transport Header)
    - bit<64> virtualAddress (8 bytes)
    - bit<32> rKey (4 bytes) 
    - bit<32> dmaLength (4 bytes)
    """
    reth_bytes = b''
    reth_bytes += struct.pack(">Q", virtual_addr & 0xFFFFFFFFFFFFFFFF)  # 8 bytes virtual address
    reth_bytes += struct.pack(">I", rkey & 0xFFFFFFFF)                  # 4 bytes rKey
    reth_bytes += struct.pack(">I", dma_length & 0xFFFFFFFF)            # 4 bytes dmaLength
    
    assert len(reth_bytes) == 16, f"RETH length should be 16 bytes, got {len(reth_bytes)}"
    return reth_bytes


def build_immdt(immediate_data=0x87654321):
    """
    构造 4 字节的 Immediate Data (IMMDT)
    - bit<32> immediateData (4 bytes)
    """
    immdt_bytes = struct.pack(">I", immediate_data & 0xFFFFFFFF)
    assert len(immdt_bytes) == 4, f"IMMDT length should be 4 bytes, got {len(immdt_bytes)}"
    return immdt_bytes


def build_rocev2_packet(opcode, dst_mac, dst_ip, dst_port, src_mac, src_ip, src_port, psn, dst_qp):
    # src_mac = "aa:bb:cc:dd:ee:01"
    # src_ip = "192.160.1.1"

    # 构造 BTH (12 bytes)
    bth = build_bth(opcode=opcode, psn=psn, dst_qp=dst_qp, ack_req=1)

    # 根据 opcode 决定是否添加 RETH/IMMDT 和默认数据
    if opcode == 0x06:  # RDMA Write First - 需要 RETH
        reth = build_reth(virtual_addr=0x1000000000000000, rkey=0x12345678, dma_length=256)
        data_payload = reth + b'\xAA\xBB\xCC\xDD' * 16  # RETH + 64 bytes data
    elif opcode == 0x09:  # RDMA Write Last - 需要 IMMDT
        immdt = build_immdt(immediate_data=0x87654321)
        data_payload = immdt + b'\xFF\xEE\xDD\xCC' * 8  # IMMDT + 32 bytes data
    else:
        data_payload = b'\xDE\xAD\xBE\xEF' * 4  # 16 bytes default data
    
    # 构造 Invariant CRC (4 bytes) - 简单示例，实际应该根据 BTH 和数据计算
    icrc = struct.pack(">I", 0x12345678)  # 4 字节 iCRC，实际部署时应计算真实 CRC
    
    # 组装完整负载：BTH + data + iCRC
    payload = bth + data_payload + icrc

    eth = Ether(src=src_mac, dst=dst_mac)
    ip = IP(src=src_ip, dst=dst_ip)
    udp = UDP(sport=src_port, dport=dst_port)

    pkt = eth / ip / udp / Raw(load=payload)
    return pkt

def send_one(iface, opcode, psn, dst_qp):
    dst_mac = "04:3f:72:9f:2b:e5"
    dst_ip = "11.11.11.200"
    dst_port = 4791
    src_mac = "0c:42:a1:9c:0f:af"
    src_ip = "11.11.11.108"
    src_port = 12345
    pkt = build_rocev2_packet(opcode=opcode, dst_mac=dst_mac, dst_ip=dst_ip, dst_port=dst_port,
                              src_mac=src_mac, src_ip=src_ip, src_port=src_port, psn=psn, dst_qp=dst_qp)
    sendp(pkt, iface=iface, verbose=True)

if __name__ == "__main__":
    iface = "ens255f1np1"
    psn = 0x01  # 初始 PSN
    dst_qp = 0x11  # 目标 QP 24bit
    while(True):
        time.sleep(1.0)
        send_one(iface,0x06, psn, dst_qp)  # BTH + RETH + Data + iCRC
        psn += 1
        send_one(iface,0x07, psn, dst_qp)  # BTH + Data + iCRC  
        psn += 1
        send_one(iface,0x09, psn, dst_qp)  # BTH + IMMDT + Data + iCRC
        psn += 1
        if psn >= 0xFFFFFE:
            psn = 0x01
