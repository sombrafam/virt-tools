#!/bin/bash

# Default configuration
declare -A DEVICE_MAP  # Maps bridges to their physical devices
HOST_IP_MAP=""
BRIDGES=("oam:10" "admin:20" "public:30" "internal:40" "ext:50" "k8s:60")
NETWORK_PREFIX="10.10"
XML_TEMPLATE_FILE="$(dirname "$0")/network-template.xml"
XML_OUTPUT_DIR="."
EXTERNAL_NIC=""
USE_VLANS=false

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --device MAP          Map physical device to bridge(s) (e.g., eth0:public,admin or eth1:oam)"
    echo "  -h, --host-ip HOST:IP     Map hostname to IP (e.g., romano:1,x1:3,host2:5)"
    echo "  -b, --bridge NAME:ID      Add bridge with VLAN ID (e.g., oam:10,admin:20)"
    echo "  -p, --prefix PREFIX       Network prefix (default: 10.10)"
    echo "  -o, --output-dir DIR      Directory to store generated XML files (default: current directory)"
    echo "  -e, --external-nic DEV External device used for internet access (e.g., eth0)"
    echo "  --use-vlans               Configure VLANs for bridges with physical devices"
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
        -e|--external-nic)
            EXTERNAL_NIC="$2"
            shift 2
            ;;
        --use-vlans)
            USE_VLANS=true
            shift
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
    sudo virsh net-info $1 &>/dev/null
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

# Configure firewall and NAT
configure_firewall() {
    local br="$1"
    local dev="$2"
    local id="$3"
    
    # Enable IP forwarding
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    
    # Add firewall rules for the bridge
    sudo iptables -I FORWARD -i "${br}" -o "${br}" -j ACCEPT
    
    # If this bridge has a physical device mapped to it
    if [ -n "$dev" ]; then
        # Allow traffic from bridge to physical device and back
        sudo iptables -I FORWARD -i "${br}" -o "${dev}" -j ACCEPT
        sudo iptables -I FORWARD -i "${dev}" -o "${br}" -j ACCEPT
        
        # No NAT needed for bridges with physical devices
        echo "Bridge ${br} has physical device ${dev}, no NAT needed"
    # If external device is specified and this bridge doesn't have a physical device
    elif [ -n "$EXTERNAL_NIC" ]; then
        # Allow traffic from bridge to external device and back
        sudo iptables -I FORWARD -i "${br}" -o "${EXTERNAL_NIC}" -j ACCEPT
        sudo iptables -I FORWARD -i "${EXTERNAL_NIC}" -o "${br}" -j ACCEPT
        
        # Set up NAT for outbound traffic from bridge to external device
        sudo iptables -t nat -I POSTROUTING -s "${NETWORK_PREFIX}.${id}.0/24" -o "${EXTERNAL_NIC}" -j MASQUERADE
        echo "Bridge ${br} using external device ${EXTERNAL_NIC} for NAT"
    else
        echo "Bridge ${br} has no physical device and no external device specified, no NAT configured"
    fi
}

# Create network vlans
for bridge in "${BRIDGES[@]}"; do
    IFS=':' read -r br id <<< "$bridge"
    NET_NAME="${br}"

    # Set IP address based on host mapping
    IP_ADDR="${NETWORK_PREFIX}.${id}.${HOST_IP}/24"
    
    # Check if this bridge has a device mapped to it
    if [ -n "${DEVICE_MAP[$br]}" ]; then
        DEVICE="${DEVICE_MAP[$br]}"
        echo "Setting up bridge $NET_NAME with device $DEVICE"
        
        # Create bridge if it doesn't exist
        if ! ip link show "$NET_NAME" &>/dev/null; then
            echo "Creating bridge $NET_NAME"
            sudo ip link add name "$NET_NAME" type bridge
            sudo ip link set dev "$NET_NAME" up
        else
            echo "Bridge $NET_NAME already exists"
        fi
        
        # Configure VLAN only if --use-vlans is specified
        if $USE_VLANS; then
            # Create VLAN interface if it doesn't exist
            VLAN_IF="${DEVICE}.${id}"
            if ! ip link show "$VLAN_IF" &>/dev/null; then
                echo "Creating VLAN interface $VLAN_IF"
                sudo ip link add link "$DEVICE" name "$VLAN_IF" type vlan id "$id"
                sudo ip link set dev "$VLAN_IF" up
            else
                echo "VLAN interface $VLAN_IF already exists"
            fi
            
            # Add VLAN interface to bridge if not already added
            if ! ip link show "$VLAN_IF" | grep -q "master $NET_NAME"; then
                echo "Adding VLAN interface $VLAN_IF to bridge $NET_NAME"
                sudo ip link set dev "$VLAN_IF" master "$NET_NAME"
            else
                echo "VLAN interface $VLAN_IF already added to bridge $NET_NAME"
            fi
        else
            # If not using VLANs, add the physical device directly to the bridge
            if ! ip link show "$DEVICE" | grep -q "master $NET_NAME"; then
                echo "Adding device $DEVICE directly to bridge $NET_NAME (no VLAN)"
                sudo ip link set dev "$DEVICE" master "$NET_NAME"
            else
                echo "Device $DEVICE already added to bridge $NET_NAME"
            fi
        fi
        
        # Set IP address on bridge
        if ! ip addr show dev "$NET_NAME" | grep -q "$IP_ADDR"; then
            echo "Setting IP address $IP_ADDR on bridge $NET_NAME"
            sudo ip addr add "$IP_ADDR" dev "$NET_NAME"
        else
            echo "IP address $IP_ADDR already set on bridge $NET_NAME"
        fi
    else
        echo "No device mapped to bridge $NET_NAME, creating a virtual bridge"
        
        # Create bridge if it doesn't exist
        if ! ip link show "$NET_NAME" &>/dev/null; then
            echo "Creating bridge $NET_NAME"
            sudo ip link add name "$NET_NAME" type bridge
            sudo ip link set dev "$NET_NAME" up
        else
            echo "Bridge $NET_NAME already exists"
        fi
        
        # Set IP address on bridge
        if ! ip addr show dev "$NET_NAME" | grep -q "$IP_ADDR"; then
            echo "Setting IP address $IP_ADDR on bridge $NET_NAME"
            sudo ip addr add "$IP_ADDR" dev "$NET_NAME"
        else
            echo "IP address $IP_ADDR already set on bridge $NET_NAME"
        fi
    fi

    # Configure firewall and NAT
    configure_firewall "$NET_NAME" "${DEVICE_MAP[$br]}" "$id"

    # Check if virsh network exists
    XML_FILE="${XML_OUTPUT_DIR}/net-${br}.xml"
    
    # Create XML file if it doesn't exist
    if [ ! -f "$XML_FILE" ]; then
        create_network_xml "$br"
    fi
    
    if [ -f "$XML_FILE" ]; then
        if ! virsh_net_exists $NET_NAME; then
            echo "Creating virsh network $NET_NAME from $XML_FILE"
            sudo virsh net-define "$XML_FILE"
            sudo virsh net-start $NET_NAME
            sudo virsh net-autostart $NET_NAME
        else
            echo "Virsh network $NET_NAME already exists"
            if ! sudo  virsh net-info $NET_NAME | grep -q "Active:.*yes"; then
                echo "Starting virsh network $NET_NAME"
                sudo virsh net-start $NET_NAME
            fi
            if ! sudo virsh net-info $NET_NAME | grep -q "Autostart:.*yes"; then
                echo "Setting virsh network $NET_NAME to autostart"
                sudo virsh net-autostart $NET_NAME
            fi
        fi
    else
        echo "Error: Failed to create XML configuration file for $NET_NAME"
        exit 1
    fi
done

echo "Network setup completed successfully"