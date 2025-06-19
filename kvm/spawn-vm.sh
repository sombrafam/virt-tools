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

# Function to generate a unique MAC address with given prefix
generate_mac() {
    local prefix=$1
    local index=$2
    # Generate 3 random bytes for the MAC address
    local byte1=$(generate_random_hex)
    local byte2=$(generate_random_hex)
    local byte3=$(generate_random_hex)
    # Format: 52:54:00:XX:XX:XX
    echo "${prefix}:${byte1}:${byte2}:${byte3}"
}

usage() {
    echo "Usage: $0 --name <hostname> --vcpus <vcpus> --mem <memory MB> --disk <disk GB>"
    echo "  [--series <trusty|xenial|bionic|focal|jammy>]"
    echo "  [--maas]"
    echo "  [--networks <network1>[,<network2>...]]  Comma-separated list of networks (e.g., maas-admin,maas-public,maas-internal)"
    echo "  [--network-prefix <prefix>]             MAC address prefix (default: 52:54:00)"
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
            IFS=',' read -ra NETWORKS <<< "$2"
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
        # Generate a unique MAC address for each network interface
        # Use the index to make the last byte unique
        mac=$(generate_mac "${NETWORK_PREFIX}" "$i")
        NETWORK_OPTS+=("--network" "network=${NETWORKS[$i]},model=virtio,mac=$mac")
        echo "Network ${NETWORKS[$i]} will use MAC: $mac"
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
        --boot hd,network
        --os-type linux
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
            # Generate a unique MAC address for each network interface
            mac=$(generate_mac "${NETWORK_PREFIX}" "$i")
            NETWORK_OPTS+=("--network=network=${NETWORKS[$i]},model=virtio,mac=$mac")
            echo "Network ${NETWORKS[$i]} will use MAC: $mac"
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
        --os-type linux
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
