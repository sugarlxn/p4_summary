from ipaddress import ip_address
import os,time,atexit
os.environ['SDE'] = "/".join(os.environ['PATH'].split(":")[0].split("/"))
os.environ['SDE_INSTALL'] = "/".join([os.environ['SDE'], 'install'])
print("%env SDE         {}".format(os.environ['SDE']))
print("%env SDE_INSTALL {}".format(os.environ['SDE_INSTALL']))

p4 = bfrt.ecmp.pipe

arp_host = p4.Ingress.arp_host
ecmp_select_t = p4.Ingress.ecmp_select_t

arp_host.add_with_unicast_send(proto_dst_addr=ip_address("192.168.168.1"), port=436)
arp_host.add_with_unicast_send(proto_dst_addr=ip_address("192.168.168.2"), port=432)
arp_host.dump()

ecmp_select_t.add_with_ecmp_select(dst_addr=ip_address("192.168.168.1"), ecmp=0, port=436)
ecmp_select_t.add_with_ecmp_select(dst_addr=ip_address("192.168.168.1"), ecmp=1, port=436)
ecmp_select_t.add_with_ecmp_select(dst_addr=ip_address("192.168.168.2"), ecmp=0, port=432)
ecmp_select_t.add_with_ecmp_select(dst_addr=ip_address("192.168.168.2"), ecmp=1, port=64)
ecmp_select_t.dump()
