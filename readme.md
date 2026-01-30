# p4 switch quick start


## 1. set server ip addr and route neigh
1. add ip addr to NIC
```shell
#node1
sudo ifconfig enp152s0np0 192.168.168.1/24
#node2
sudo ifconfig enp75s0np0 192.168.168.2/24
# or 
#node1
sudo ip addr add 192.168.168.1/24 dev enp152s0np0
#node2 
sudo ip addr add 192.168.168.2/24 dev enp75s0np0
```
2. set route
```shell
#node1
sudo ip neigh add 192.168.168.2 lladdr 50:6b:4b:dd:f0:e6 dev enp152s0np0 nud permanent
#node2
sudo ip neigh add 192.168.168.1 lladdr 98:03:9b:c8:67:08 dev enp75s0np0 nud permanent
#or
#node1
sudo ip neigh replace 192.168.168.2 lladdr 50:6b:4b:dd:f0:e6 dev enp152s0np0 nud permanent
#node2
sudo ip neigh add 192.168.168.1 lladdr 98:03:9b:c8:67:08 dev enp75s0np0 nud permanent
```
## 2. run p4 program

1. set env 
```shell
. set_sde_env.bash
```

2. load mod
```shell
. mod_load.sh
```

3. build p4 source file
```shell
$SDE/p4_build.sh <file_path_to_p4>.p4
```

4. run p4 program
```shell
$SDE/run_switchd.sh -p <file_path_to_p4>
```

5. add port
```shell
$SDE/run_bfshell.sh -f port.txt
```

6. load setup.py
```shell
$SDE/run_bfshell.sh -b setup.py -i 
```
