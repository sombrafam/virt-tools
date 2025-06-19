#!/bin/bash

# Default configuration
declare -A DEVICE_MAP  # Maps bridges to their physical devices
HOST_IP_MAP=""
BRIDGES=("oam:10" "admin:20" "public:30" "internal:40" "ext:50" "k8s:60")
NETWORK_PREFIX="10.10"
XML_TEMPLATE_FILE="$(dirname "$0")/network-template.xml"
XML_OUTPUT_DIR="."

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --device MAP          Map physical device to bridge(s) (e.g., eth0:public,admin or eth1:oam)"
    echo "  -h, --host-ip HOST:IP     Map hostname to IP (e.g., romano:1,x1:3,host2:5)"
    echo "  -b, --bridge NAME:ID      Add bridge with VLAN ID (e.g., oam:10,admin:20)"
    echo "  -p, --prefix PREFIX       Network prefix (default: 10.10)"
    echo "  -o, --output-dir DIR      Directory to store generated XML files (default: current directory)"
    echo "  --help                    Show this help message"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--device)
            NETDEV="$2"
            shift 2
            ;;
        -h|--host-ip)
            HOST_IP_MAP="$2"
            shift 2
            ;;
        -b|--bridge)
            IFS=',' read -r -a BRIDGES <<< "$2"
            shift 2
            ;;
        -p|--prefix)
            NETWORK_PREFIX="$2"
            shift 2
            ;;
        -o|--output-dir)
            XML_OUTPUT_DIR="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$HOST_IP_MAP" ]; then
    echo "Error: Host to IP mapping not specified"
    echo "Use -h or --host-ip to map hostnames to IP addresses"
    exit 1
fi

# Parse host IP mapping
declare -A HOST_IPS
IFS=',' read -ra MAPPINGS <<< "$HOST_IP_MAP"
for map in "${MAPPINGS[@]}"; do
    IFS=':' read -r host ip <<< "$map"
    HOST_IPS["$host"]="$ip"
done

# Get current hostname
HOSTNAME=$(hostname)
if [ -z "${HOST_IPS[$HOSTNAME]}" ]; then
    echo "Error: No IP mapping found for host: $HOSTNAME"
    echo "Available mappings: ${!HOST_IPS[*]}"
    exit 1
fi

HOST_IP=${HOST_IPS[$HOSTNAME]}

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

# Function to create XML network configuration file
create_network_xml() {
    local bridge_name="$1"
    local output_file="${XML_OUTPUT_DIR}/net-${bridge_name}.xml"
    local network_name="${bridge_name}"
    
    # Check if template file exists
    if [ -f "$XML_TEMPLATE_FILE" ]; then
        # Use template and replace placeholders
        sed "s/__NETWORK_NAME__/${network_name}/g; s/__BRIDGE_NAME__/${network_name}/g" "$XML_TEMPLATE_FILE" > "$output_file"
        echo "Generated XML file from template: $output_file"
        return 0
    else
        echo "Error: XML template file not found at $XML_TEMPLATE_FILE"
        exit 1
    fi
}

# Create network vlans
for bridge in "${BRIDGES[@]}"; do
    IFS=':' read -r br id <<< "$bridge"
    
    # Skip VLAN creation if no device is mapped to this bridge
    if [ -z "${DEVICE_MAP[$br]}" ]; then
        echo "No physical device mapped to bridge $br, skipping VLAN creation"
        continue
    fi
    
    NETDEV=${DEVICE_MAP[$br]}
    if ! vlan_exists $id; then
        echo "Creating VLAN $id for bridge $br on device $NETDEV"
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

# Create bridges and configure networks
for bridge in "${BRIDGES[@]}"; do
    IFS=':' read -r br id <<< "$bridge"
    NET_NAME="${br}"

    # Set IP address based on host mapping
    IP_ADDR="${NETWORK_PREFIX}.${id}.${HOST_IP}/24"

    # Check if bridge exists
    if ! bridge_exists $NET_NAME; then
        echo "Creating bridge $NET_NAME"
        sudo brctl addbr $NET_NAME

        # Add physical interface to bridge if mapped
        if [ -n "${DEVICE_MAP[$br]}" ]; then
            if ! ip link show vlan${id} | grep -q "master"; then
                echo "Adding vlan${id} to bridge $NET_NAME"
                sudo brctl addif $NET_NAME vlan${id}
            else
                echo "VLAN ${id} is already part of a bridge, skipping addition"
            fi
        else
            echo "No physical device mapped to bridge $NET_NAME, creating standalone bridge"
        fi

        if [ -n "$IP_ADDR" ]; then
            echo "Setting IP $IP_ADDR on $NET_NAME"
            sudo ip addr add $IP_ADDR dev $NET_NAME
            sudo ip link set dev $NET_NAME up
        fi
    else
        echo "Bridge $NET_NAME already exists, checking configuration"

        # Only manage VLAN interface if this bridge has a physical device mapped
        if [ -n "${DEVICE_MAP[$br]}" ]; then
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
    NETWORK="${NETWORK_PREFIX}.${id}.0/24"
    
    if ! sudo iptables -C FORWARD -s ${NETWORK} -j ACCEPT &>/dev/null; then
        echo "Adding firewall rule for source network ${NETWORK}"
        sudo iptables -I FORWARD -s ${NETWORK} -j ACCEPT
    else
        echo "Firewall rule for source network ${NETWORK} already exists"
    fi

    if ! sudo iptables -C FORWARD -d ${NETWORK} -j ACCEPT &>/dev/null; then
        echo "Adding firewall rule for destination network ${NETWORK}"
        sudo iptables -I FORWARD -d ${NETWORK} -j ACCEPT
    else
        echo "Firewall rule for destination network ${NETWORK} already exists"
    fi

    # Only add NAT rules if this bridge has a physical device mapped
    if [ -n "${DEVICE_MAP[$br]}" ]; then
        if ! sudo iptables -t nat -C POSTROUTING -o ${DEVICE_MAP[$br]} -s ${NETWORK} -j MASQUERADE &>/dev/null; then
            echo "Adding NAT masquerade rule for network ${NETWORK}"
            sudo iptables -t nat -I POSTROUTING -o ${DEVICE_MAP[$br]} -s ${NETWORK} -j MASQUERADE
        else
            echo "NAT masquerade rule for network ${NETWORK} already exists"
        fi
    else
        echo "No physical device mapped to bridge $br, skipping NAT masquerade rule"
    fi

    # Check if virsh network exists
    XML_FILE="${XML_OUTPUT_DIR}/net-${br}.xml"
    
    # Create XML file if it doesn't exist
    if [ ! -f "$XML_FILE" ]; then
        create_network_xml "$br"
    fi
    
    if [ -f "$XML_FILE" ]; then
        if ! virsh_net_exists $NET_NAME; then
            echo "Creating virsh network $NET_NAME from $XML_FILE"
            virsh net-define "$XML_FILE"
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
    else
        echo "Error: Failed to create XML configuration file for $NET_NAME"
        exit 1
    fi
done

echo "Network setup completed successfully"