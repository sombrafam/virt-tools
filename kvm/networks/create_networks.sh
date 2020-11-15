#!/bin/bash

# 10:oam, 20:admin, 30:public, 40:internal, 50:ext, 60:k8s

HOSTNAME=$(hostname)
if [ ${HOSTNAME} == "asus" ]; then
    NETDEV=${NETDEV:-enp2s0}
else
    if [ ${HOSTNAME} == "x1" ]; then
        NETDEV=${NETDEV:-enx000ec6c38af4}
    else
        echo "Can not run in host: ${HOSTNAME}"
        exit 1
    fi
fi

# Create network vlans
for id in $(seq 10 10 60); do
    sudo ip link add link ${NETDEV} name vlan${id} type vlan id ${id}
    sudo ifconfig vlan${id} 0.0.0.0 up
done

id=10
for br in oam admin public internal ext k8s; do
    sudo brctl addbr maas-${br}
    sudo brctl addif maas-${br} vlan${id}
    if [ ${HOSTNAME} == "asus" ]; then
        sudo ifconfig maas-${br} 10.10.${id}.1/24 up
    else
        if [ ${HOSTNAME} == "x1" ]; then
            sudo ifconfig maas-${br} 10.10.${id}.3/24 up
        else
            echo "Can not run in host: ${HOSTNAME}"
        fi
    fi

    sudo iptables -I FORWARD -s 10.10.${id}.0/24 -j ACCEPT
    sudo iptables -I FORWARD -d 10.10.${id}.0/24 -j ACCEPT
    sudo iptables -t nat -I POSTROUTING -o ${NETDEV} -s 10.10.${id}.0/24 -j MASQUERADE

    # TODO: check if networks already exist first
    virsh net-define maas-net-${br}.xml
    virsh net-start maas-${br}
    virsh net-autostart maas-${br}
    id=$((id+10))
done

