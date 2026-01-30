from ipaddress import ip_address
import os,time,atexit
os.environ['SDE'] = "/".join(os.environ['PATH'].split(":")[0].split("/"))
os.environ['SDE_INSTALL'] = "/".join([os.environ['SDE'], 'install'])
print("%env SDE         {}".format(os.environ['SDE']))
print("%env SDE_INSTALL {}".format(os.environ['SDE_INSTALL']))

p4 = bfrt.mirror_digest.pipe
p4_learn =  p4.IngressDeparser
p4_time_out_digest = p4.IngressDeparser.pipe.IngressDeparser

# nexthop
nexthop = p4.Ingress.nexthop
nexthop.add_with_send(nexthop_id=0, port=144)
nexthop.add_with_send(nexthop_id=1, port=128)
# ipv4_host
ipv4_host = p4.Ingress.ipv4_host
ipv4_host.add_with_set_nexthop(dst_addr=ip_address("11.11.11.200"), nexthop=0)
ipv4_host.add_with_set_nexthop(dst_addr=ip_address("11.11.11.108"), nexthop=1)
# digest
rdma_acl = p4.Ingress.rdma_acl
#random_drop, 设置丢包range(random_value_start, random_value_end)，范围内的包丢弃,p4内置随机数Random<bit<16>>(0,65535)
random_drop = p4.Ingress.random_drop
rate = 0
random_value_end = int(65535*rate)
print("drop_rate:",rate,"random_value_end:",random_value_end)
#random_drop.add_with_set_drop(random_value_start=0,random_value_end=random_value_end,MATCH_PRIORITY=0)
# time out pkt threshold, 大于阈值的pkt，触发time out digest, time out 时间为48bit, 拆分为3个部分，每个部分16bit
# timestamp_diff_threshold(ns) = (timestamp_diff_3 << 32) | (timestamp_diff_2 << 16) | timestamp_diff_1
# 当 实际的pkt间隔时间分别 in rang(start, end)，触发time out digest, 
# 下面是1ms的例子， 1ms = 0x0000 000F 4240， 由于3部分均要成立所以要舍弃低16bit的精度，变为0x0000 000F 0000，即0.98304 ms
time_out_pkt = p4.Ingress.time_out_pipe.time_out_pkt
time_out_pkt.add_with_set_time_out(timestamp_diff_1_start=0x0000, timestamp_diff_1_end=0xffff,
                                   timestamp_diff_2_start=0x3b9a, timestamp_diff_2_end=0xffff,
                                   timestamp_diff_3_start=0x0000, timestamp_diff_3_end=0xffff)


src_ip = 0x0000
dst_ip = 0x0000
src_port = 0x00
dst_port = 0x00
destinationQP = 0x000000
dmaLength = 0x00000000
flow_table = {(src_ip, dst_ip, src_port, dst_port, destinationQP):
                      { "dmaLength":dmaLength,
                        "first_pkt_tstamp":0x000000000000,
                        "last_pkt_tstamp":0x000000000000}
             }
# 将统计的流条目写到一个文件中，方便后续分析
time_now = time.strftime("%Y%m%d-%H%M%S", time.localtime())
dir = "/root/out_put_data/"
filename = "flow_table_{}.csv".format(time_now)
f = open(dir+filename, "a")
f.write("src_ip,dst_ip,src_port,dst_port,destinationQP,dmaLength,first_pkt_tstamp,last_pkt_tstamp\n")
atexit.register(f.close)


def my_learning_cb(dev_id, pipe_id, direction, parser_id, session, msg):
    global p4,flow_table,f    
    
    for digest in msg: # [{'srcip': xxx},{}]
        src_ip = digest["src_ip"]
        dst_ip = digest["dst_ip"]
        src_port = digest["src_port"]
        dst_port = digest["dst_port"]
        opcode = digest["opcode"]
        global_tstamp = digest["ingress_global_tstamp"]
        destinationQP = digest["destinationQP"]
        dmaLength = digest["dmaLength"]
        key = (src_ip, dst_ip, src_port, dst_port, destinationQP)
        if key not in flow_table and opcode == 0x06:  # RDMA Write first pkt
            flow_table[key] = {"dmaLength":dmaLength,"first_pkt_tstamp":global_tstamp, "last_pkt_tstamp":0x000000000000}
        if key in flow_table and opcode == 0x09: # RDMA write last pkt
            flow_table[key]["last_pkt_tstamp"] = global_tstamp
            first_pkt_tstamp = flow_table[key]["first_pkt_tstamp"]
            last_pkt_tstamp = flow_table[key]["last_pkt_tstamp"]
            dmaLength = flow_table[key]["dmaLength"]
            if first_pkt_tstamp != 0 and last_pkt_tstamp != 0:
                #写入文件
                f.write("{},{},{},{},{},{},{},{}\n".format(key[0], key[1], key[2], key[3], key[4],dmaLength,first_pkt_tstamp, last_pkt_tstamp))
                print("Flow {} writed.".format(key))
                #删除flow entry
                del flow_table[key]
    return 0

def time_out_digest_callback(dev_id, pipe_id, direction, parser_id, session, msg):
    for digest in msg:
        diff1  = digest["timestamp_diff_1"]
        diff2  = digest["timestamp_diff_2"]
        diff3  = digest["timestamp_diff_3"]
        diff = (diff3<<32)|(diff2<<16)|diff1
        print("Time out digest received with 3:{},2:{},1:{}, timestamp_diff:{}".format(diff3,diff2,diff1,diff))
    return 0

try:
    p4_learn.opcode_digest.callback_deregister()
    p4_time_out_digest.time_out_digest.callback_deregister()
except:
    pass
finally:
    print("Deregistering old learning callback (if any)")                   

p4_learn.opcode_digest.callback_register(my_learning_cb)
p4_time_out_digest.time_out_digest.callback_register(time_out_digest_callback)
print("Learning callback registered")

