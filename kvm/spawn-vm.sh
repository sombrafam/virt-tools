#!/bin/bash -e

export -A IMAGES=()
BASE_FOLDER="${HOME}/VMScripts"
IMAGE_FOLDER="${HOME}/VMStorage/Images"
DISK_FOLDER="${HOME}/VMStorage/Disks"
MAAS=false
NETWORK="default"
NETWORKS=()
NETWORK_PREFIX="52:54:00"
FORCE=false

# Define image paths
IMAGES["trusty"]="${IMAGE_FOLDER}/trusty-server-cloudimg-amd64-disk1.img"
IMAGES["xenial"]="${IMAGE_FOLDER}/xenial-server-cloudimg-amd64-disk1.img"
IMAGES["bionic"]="${IMAGE_FOLDER}/bionic-server-cloudimg-amd64.img"
IMAGES["focal"]="${IMAGE_FOLDER}/focal-server-cloudimg-amd64.img"
IMAGES["jammy"]="${IMAGE_FOLDER}/jammy-server-cloudimg-amd64.img"
IMAGES["centos7"]="${IMAGE_FOLDER}/CentOS-7-x86_64-GenericCloud.qcow2"

# Function to check if host supports hardware virtualization
check_virtualization_support() {
    # Check if CPU supports virtualization
    if grep -q -E 'vmx|svm' /proc/cpuinfo; then
        # Check if KVM module is loaded
        if lsmod | grep -q kvm; then
            # Check if we're running in a VM
            if [ -e /sys/hypervisor/type ] || grep -q -E 'KVM|QEMU|VMware|VirtualBox|Xen' /proc/cpuinfo /proc/version /proc/interrupts /proc/modules 2>/dev/null; then
                echo "Running in a VM with nested virtualization support"
                return 1  # Return 1 for nested virtualization
            else
                echo "Running on physical hardware with virtualization support"
                return 0  # Return 0 for physical hardware
            fi
        else
            echo "CPU supports virtualization but KVM module is not loaded"
            return 2  # Return 2 for no KVM module
        fi
    else
        echo "CPU does not support hardware virtualization"
        return 3  # Return 3 for no virtualization support
    fi
}

# Function to generate a random byte in hex format
generate_random_hex() {
    printf '%02x' $((RANDOM % 256))
}

# Function to generate a MAC address
generate_mac() {
    local prefix="$1"
    local index="$2"
    local id="$3"
    
    # Generate two random bytes
    local byte1=$(generate_random_hex)
    local byte2=$(generate_random_hex)
    
    # If ID is provided, use it as the last byte, otherwise generate a random one
    if [ -n "$id" ]; then
        echo "${prefix}:${byte1}:${byte2}:${id}"
    else
        local byte3=$(generate_random_hex)
        echo "${prefix}:${byte1}:${byte2}:${byte3}"
    fi
}

usage() {
    echo "Usage: $0 --name <name> --vcpus <vcpus> --mem <memory> --disk <size> [options]"
    echo "Options:"
    echo "  --name <name>                    Name of the VM"
    echo "  --vcpus <vcpus>                  Number of virtual CPUs"
    echo "  --mem <memory>                   Memory in MB"
    echo "  --disk <size>                    Disk size in GB"
    echo "  [--series <trusty|xenial|bionic|focal|jammy>]"
    echo "  [--maas]                         Enable MAAS support"
    echo "  [--networks <network1:id1>[,<network2:id2>...]]"
    echo "                                   Comma-separated list of networks with IDs"
    echo "                                   Example: --networks public:30,admin:20,oam:10"
    echo "                                   The ID is used in the MAC address generation"
    echo "  [--network-prefix <prefix>]      MAC address prefix (default: 52:54:00)"
    echo "  [--debug]                        Enable debug output"
    echo "  [--help]                         Show this help message"
}

if [ -z $1 ] || [ -z $2 ]; then
    usage
    exit 1
fi


while (($# > 0)); do
    case "$1" in
        --name)
            VMNAME=$2
            shift
            ;;
        --vcpus)
            VCPUS=$2
            shift
            ;;
        --mem)
            MEMORY=$2
            shift
            ;;
        --disk)
            DISK=$2
            shift
            ;;
        --series)
            SERIES=$2
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        --maas)
            MAAS=true
            ;;
        --networks)
            # Split the comma-separated list into an array
            IFS=',' read -r -a NETWORKS <<< "$2"
            shift
            ;;
        --network-prefix)
            NETWORK_PREFIX=$2
            shift
            ;;
        --net)
            NETWORK=$2
            shift
            ;;
        --debug)
            set -x
            ;;
        *)
            echo "Invalid input parameter: ${1}"
            exit 1
            ;;
    esac
    shift
done

VCPUS=${VCPUS:-2}
MEMORY=${MEMORY:-2048}
DISK=${DISK:-20}
SERIES=${SERIES:-"focal"}
NETWORK=${NETWORK:-"default"}
USER=$(whoami)

# cd ${BASE_FOLDER}
echo "Updating cloud-init scripts"
cp ${BASE_FOLDER}/cloud-config-template ${BASE_FOLDER}/cloud-config
sed -i "s/hostname:.*/hostname: ${VMNAME}/g" ${BASE_FOLDER}/cloud-config
cloud-localds ${DISK_FOLDER}/vmconfigs-${VMNAME}.iso ${BASE_FOLDER}/cloud-config
sudo chown ${USER}:${USER} ${DISK_FOLDER}/vmconfigs-${VMNAME}.iso
sudo setfacl -m u:libvirt-qemu:rwx ${DISK_FOLDER}/vmconfigs-${VMNAME}.iso
rm ${BASE_FOLDER}/cloud-config

if [ ! -f ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2 ]; then
    echo "Creating disk images..."
    if [ ${MAAS} == "true" ]; then
        sudo qemu-img create -f qcow2 ${DISK_FOLDER}/vmdisk-${VMNAME}-root.qcow2 "${DISK}"G
        sudo qemu-img create -f qcow2 ${DISK_FOLDER}/vmdisk-${VMNAME}-01.qcow2 20G
        sudo chown ${USER}:${USER} ${DISK_FOLDER}/vmdisk-${VMNAME}-root.qcow2
        sudo chown ${USER}:${USER} ${DISK_FOLDER}/vmdisk-${VMNAME}-01.qcow2
        sudo setfacl -m u:libvirt-qemu:rwx ${DISK_FOLDER}/vmdisk-${VMNAME}-root.qcow2
        sudo setfacl -m u:libvirt-qemu:rwx ${DISK_FOLDER}/vmdisk-${VMNAME}-01.qcow2
    else
        sudo qemu-img convert -f qcow2 -O qcow2 ${IMAGES[${SERIES}]} ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2
        sudo qemu-img resize  ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2 "${DISK}"G
        sudo chown ${USER}:${USER} ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2
        sudo setfacl -m u:libvirt-qemu:rwx ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2
    fi
else
    echo "Warning: Disk image already exists for vm with name ${VMNAME}"
fi


if [ ${MAAS} == "true" ]; then
    echo "Creating VM with MAAS support"
    
    # Default networks if none specified
    if [ ${#NETWORKS[@]} -eq 0 ]; then
        NETWORKS=("maas-admin" "maas-public" "maas-internal")
        echo "No networks specified, using defaults: ${NETWORKS[*]}"
    fi
    
    # Build network options for virt-install
    NETWORK_OPTS=()
    for i in "${!NETWORKS[@]}"; do
        # Parse network name and ID
        IFS=':' read -r net_name net_id <<< "${NETWORKS[$i]}"
        
        if [ -z "$net_id" ]; then
            echo "Warning: Network ${net_name} has no ID specified, using index as ID"
            net_id=$i
        fi
        
        # Generate a MAC address using the network ID
        mac=$(generate_mac "${NETWORK_PREFIX}" "$i" "$net_id")
        NETWORK_OPTS+=("--network" "network=${net_name},model=virtio,mac=$mac")
        echo "Network ${net_name} with ID ${net_id} will use MAC: $mac"
    done
    
    # Check if host supports hardware virtualization
    VIRT_OPTS=()
    check_virtualization_support
    VIRT_SUPPORT=$?
    
    if [ $VIRT_SUPPORT -eq 0 ]; then
        # Physical hardware with virtualization support
        VIRT_OPTS+=("--virt-type=kvm" "--cpu=host-passthrough")
        echo "Using KVM acceleration with host-passthrough CPU"
    elif [ $VIRT_SUPPORT -eq 1 ]; then
        # Nested virtualization
        VIRT_OPTS+=("--virt-type=kvm")
        echo "Using KVM acceleration"
    else
        # No hardware virtualization
        VIRT_OPTS+=("--virt-type=qemu")
        echo "Using QEMU emulation (no hardware acceleration)"
    fi
    
    # Build the virt-install command
    CMD=(
        sudo virt-install
        --name "$VMNAME"
        --memory "$MEMORY"
        --vcpus "$VCPUS"
        --disk "path=${DISK_FOLDER}/vmdisk-${VMNAME}-root.qcow2,format=qcow2,device=disk,bus=sata"
        --disk "path=${DISK_FOLDER}/vmdisk-${VMNAME}-01.qcow2,format=qcow2,device=disk,bus=sata"
        --disk "path=${DISK_FOLDER}/vmconfigs-${VMNAME}.iso,device=cdrom"
        --pxe
        --boot network,hd
        --os-variant ubuntu18.04
        --virt-type kvm
        --graphics spice
        --check path_in_use=off
        --noautoconsole
        "${NETWORK_OPTS[@]}"
        "${VIRT_OPTS[@]}"
    )
    
    # Execute the command
    echo "Creating VM with the following network configuration:"
    printf '  %s\n' "${NETWORK_OPTS[@]}"
    "${CMD[@]}"
else
    echo "Creating VM with no MAAS support"
    
    # Build network options for virt-install
    NETWORK_OPTS=()
    
    # If networks are specified, use them
    if [ ${#NETWORKS[@]} -gt 0 ]; then
        echo "Using specified networks: ${NETWORKS[*]}"
        for i in "${!NETWORKS[@]}"; do
            # Parse network name and ID
            IFS=':' read -r net_name net_id <<< "${NETWORKS[$i]}"
            
            if [ -z "$net_id" ]; then
                echo "Warning: Network ${net_name} has no ID specified, using index as ID"
                net_id=$i
            fi
            
            # Generate a MAC address using the network ID
            mac=$(generate_mac "${NETWORK_PREFIX}" "$i" "$net_id")
            NETWORK_OPTS+=("--network=network=${net_name},model=virtio,mac=$mac")
            echo "Network ${net_name} with ID ${net_id} will use MAC: $mac"
        done
    else
        # Use the default network
        echo "Using default network: $NETWORK"
        NETWORK_OPTS+=("--network=network=$NETWORK,model=e1000")
    fi
    
    # Check if host supports hardware virtualization
    VIRT_OPTS=()
    check_virtualization_support
    VIRT_SUPPORT=$?
    
    if [ $VIRT_SUPPORT -eq 0 ]; then
        # Physical hardware with virtualization support
        VIRT_OPTS+=("--virt-type=kvm" "--cpu=host-passthrough")
        echo "Using KVM acceleration with host-passthrough CPU"
    elif [ $VIRT_SUPPORT -eq 1 ]; then
        # Nested virtualization
        VIRT_OPTS+=("--virt-type=kvm")
        echo "Using KVM acceleration"
    else
        # No hardware virtualization
        VIRT_OPTS+=("--virt-type=qemu")
        echo "Using QEMU emulation (no hardware acceleration)"
    fi
    
    # Build the virt-install command
    CMD=(
        sudo virt-install
        --name "$VMNAME"
        --memory "$MEMORY"
        --vcpus "$VCPUS"
        --disk "path=${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2,format=qcow2,device=disk,bus=virtio"
        --disk "path=${DISK_FOLDER}/vmconfigs-${VMNAME}.iso,device=cdrom"
        --os-variant ubuntu18.04
        --graphics spice
        --import
        --check path_in_use=off
        --noautoconsole
        "${NETWORK_OPTS[@]}"
        "${VIRT_OPTS[@]}"
    )
    
    # Execute the command
    echo "Creating VM with the following network configuration:"
    printf '  %s\n' "${NETWORK_OPTS[@]}"
    "${CMD[@]}"

    ip_count=$(sudo virsh domifaddr $VMNAME | grep ipv4 | wc -l)
    echo -n "Waiting for machine to boot ."
    while [ $ip_count -ne 1 ]; do
        echo -n " ."
        sleep 1
        ip_count=$(sudo virsh domifaddr $VMNAME | grep ipv4 | wc -l)
    done
    echo ""
    ip=$(sudo virsh domifaddr $VMNAME | awk '{if ($3 == "ipv4") print $4;}'|cut -d'/' -f1)
    ssh-keyscan -H -t rsa ubuntu@$ip >> ~/.ssh/known_hosts
    echo "Virtual server $VMNAME is ready at $ip!"
    echo "You can log in the instance with:"
    echo "ssh ubuntu@$ip"
fi
