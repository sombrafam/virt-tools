#!/bin/bash
# 10:oam, 20:admin, 30:public, 40:internal, 50:ext, 60:k8s
HOSTNAME=$(hostname)
if [ ${HOSTNAME} == "romano" ]; then
    NETDEV=${NETDEV:-ens13f1np1}
else
    if [ ${HOSTNAME} == "x1" ]; then
        NETDEV=${NETDEV:-enx000ec6c38af4}
    else
        echo "Can not run in host: ${HOSTNAME}"
        exit 1
    fi
fi

# Function to check if VLAN exists
vlan_exists() {
    ip link show vlan$1 &>/dev/null
    return $?
}

# Function to check if bridge exists
bridge_exists() {
    ip link show $1 &>/dev/null
    return $?
}

# Function to check if specific IP is configured on interface
ip_is_configured() {
    local interface=$1
    local ip_address=$2
    ip addr show dev $interface | grep -q "$ip_address"
    return $?
}

# Function to check if network exists in virsh
virsh_net_exists() {
    virsh net-info $1 &>/dev/null
    return $?
}

# Create network vlans
for id in $(seq 10 10 60); do
    if ! vlan_exists $id; then
        echo "Creating VLAN $id"
        sudo ip link add link ${NETDEV} name vlan${id} type vlan id ${id}
        sudo ip link set dev vlan${id} up
    else
        echo "VLAN $id already exists, checking status"
        if ! ip link show vlan${id} | grep -q "UP"; then
            echo "Setting VLAN $id up"
            sudo ip link set dev vlan${id} up
        fi
    fi
done

id=10
for br in oam admin public internal ext k8s; do
    NET_NAME="maas-${br}"

    # Determine the correct IP address based on hostname
    # Modified to use romano as the primary hostname with IP .1
    if [ ${HOSTNAME} == "romano" ]; then
        IP_ADDR="10.10.${id}.1/24"
    elif [ ${HOSTNAME} == "asus" ]; then
        IP_ADDR="10.10.${id}.1/24"
    elif [ ${HOSTNAME} == "x1" ]; then
        IP_ADDR="10.10.${id}.3/24"
    else
        echo "Can not run in host: ${HOSTNAME}"
        IP_ADDR=""
    fi

    # Check if bridge exists
    if ! bridge_exists $NET_NAME; then
        echo "Creating bridge $NET_NAME"
        sudo brctl addbr $NET_NAME

        # Check if VLAN is already part of a bridge
        if ! ip link show vlan${id} | grep -q "master"; then
            echo "Adding vlan${id} to bridge $NET_NAME"
            sudo brctl addif $NET_NAME vlan${id}
        else
            echo "VLAN ${id} is already part of a bridge, skipping addition"
        fi

        if [ -n "$IP_ADDR" ]; then
            echo "Setting IP $IP_ADDR on $NET_NAME"
            sudo ip addr add $IP_ADDR dev $NET_NAME
            sudo ip link set dev $NET_NAME up
        fi
    else
        echo "Bridge $NET_NAME already exists, checking configuration"

        # Check if VLAN is already part of this bridge
        if ! ip link show vlan${id} | grep -q "master $NET_NAME"; then
            # Check if VLAN is part of another bridge
            if ip link show vlan${id} | grep -q "master"; then
                echo "VLAN ${id} is already part of another bridge, please check configuration manually"
            else
                echo "Adding vlan${id} to bridge $NET_NAME"
                sudo brctl addif $NET_NAME vlan${id}
            fi
        fi

        # Check if bridge is up
        if ! ip link show $NET_NAME | grep -q "UP"; then
            echo "Setting bridge $NET_NAME up"
            sudo ip link set dev $NET_NAME up
        fi

        # Check if IP is correctly configured
        if [ -n "$IP_ADDR" ]; then
            IP_WITHOUT_MASK=$(echo $IP_ADDR | cut -d'/' -f1)
            if ! ip_is_configured $NET_NAME $IP_WITHOUT_MASK; then
                echo "IP address $IP_ADDR not found on $NET_NAME, adding it"
                sudo ip addr add $IP_ADDR dev $NET_NAME
            else
                echo "IP address correctly configured on $NET_NAME"
            fi
        fi
    fi

    # Check if firewall rules already exist
    if ! sudo iptables -C FORWARD -s 10.10.${id}.0/24 -j ACCEPT &>/dev/null; then
        echo "Adding firewall rule for source network 10.10.${id}.0/24"
        sudo iptables -I FORWARD -s 10.10.${id}.0/24 -j ACCEPT
    else
        echo "Firewall rule for source network 10.10.${id}.0/24 already exists"
    fi

    if ! sudo iptables -C FORWARD -d 10.10.${id}.0/24 -j ACCEPT &>/dev/null; then
        echo "Adding firewall rule for destination network 10.10.${id}.0/24"
        sudo iptables -I FORWARD -d 10.10.${id}.0/24 -j ACCEPT
    else
        echo "Firewall rule for destination network 10.10.${id}.0/24 already exists"
    fi

    if ! sudo iptables -t nat -C POSTROUTING -o ${NETDEV} -s 10.10.${id}.0/24 -j MASQUERADE &>/dev/null; then
        echo "Adding NAT masquerade rule for network 10.10.${id}.0/24"
        sudo iptables -t nat -I POSTROUTING -o ${NETDEV} -s 10.10.${id}.0/24 -j MASQUERADE
    else
        echo "NAT masquerade rule for network 10.10.${id}.0/24 already exists"
    fi

    # Check if virsh network exists
    if ! virsh_net_exists $NET_NAME; then
        echo "Creating virsh network $NET_NAME"
        virsh net-define maas-net-${br}.xml
        virsh net-start $NET_NAME
        virsh net-autostart $NET_NAME
    else
        echo "Virsh network $NET_NAME already exists"
        if ! virsh net-info $NET_NAME | grep -q "Active:.*yes"; then
            echo "Starting virsh network $NET_NAME"
            virsh net-start $NET_NAME
        fi
        if ! virsh net-info $NET_NAME | grep -q "Autostart:.*yes"; then
            echo "Setting virsh network $NET_NAME to autostart"
            virsh net-autostart $NET_NAME
        fi
    fi

    id=$((id+10))
done

echo "Network setup completed successfully"