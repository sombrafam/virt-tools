#!/bin/bash -e

export -A IMAGES=()
BASE_FOLDER="${HOME}/VMScripts"
IMAGE_FOLDER="${HOME}/VMStorage/Images"
DISK_FOLDER="${HOME}/VMStorage/Disks"

MAAS=false

IMAGES["trusty"]="${IMAGE_FOLDER}/trusty-server-cloudimg-amd64-disk1.img"
IMAGES["xenial"]="${IMAGE_FOLDER}/xenial-server-cloudimg-amd64-disk1.img"
IMAGES["bionic"]="${IMAGE_FOLDER}/bionic-server-cloudimg-amd64.img"
IMAGES["focal"]="${IMAGE_FOLDER}/focal-server-cloudimg-amd64.img"

usage() {
    echo "Usage: $0 --name <hostname> --vcpus <vcpus> --mem <memory MB> --disk <disk GB> [--series <trusty|xenial|bionic|focal>]"
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

# cd ${BASE_FOLDER}
echo "Updating cloud-init scripts"
cp ${BASE_FOLDER}/cloud-config-template ${BASE_FOLDER}/cloud-config
sed -i "s/hostname:.*/hostname: ${VMNAME}/g" ${BASE_FOLDER}/cloud-config
sudo cloud-localds ${DISK_FOLDER}/vmconfigs-${VMNAME}.iso ${BASE_FOLDER}/cloud-config
rm ${BASE_FOLDER}/cloud-config

if [ ! -f ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2 ]; then
    echo "Creating disk images..."
    if [ ${MAAS} == "true" ]; then
        sudo qemu-img create -f qcow2 ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2 "${DISK}"G
    else
        sudo qemu-img convert -f qcow2 -O qcow2 ${IMAGES[${SERIES}]} ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2
        sudo qemu-img resize  ${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2 "${DISK}"G
    fi
else
    echo "Warning: Disk image already exists for vm with name ${VMNAME}"
    exit 1
fi

echo "Booting VM ..."
if [ ${MAAS} == "true" ]; then
    sudo virt-install \
                --name $VMNAME \
                --memory $MEMORY \
                --vcpus $VCPUS \
                --disk path=${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2,format=qcow2,device=disk,bus=sata \
                --disk path=${DISK_FOLDER}/vmconfigs-${VMNAME}.iso,device=cdrom \
                --pxe --boot hd,network \
                --os-type linux \
                --os-variant ubuntu18.04 \
                --virt-type kvm \
                --graphics spice \
                --network=network=maas-oam,model=virtio \
                --network=network=maas-admin,model=virtio \
                --network=network=maas-public,model=virtio \
                --network=network=maas-internal,model=virtio \
                --network=network=maas-ext,model=virtio \
                --network=network=maas-k8s,model=virtio \
                --check path_in_use=off \
                --noautoconsole
else
    sudo virt-install \
                --name $VMNAME \
                --memory $MEMORY \
                --vcpus $VCPUS \
                --disk path=${DISK_FOLDER}/vmdisk-${VMNAME}.qcow2,format=qcow2,device=disk,bus=virtio \
                --disk path=${DISK_FOLDER}/vmconfigs-${VMNAME}.iso,device=cdrom \
                --os-type linux \
                --os-variant ubuntu18.04 \
                --virt-type kvm \
                --graphics spice \
                --network network=new-dhcp,model=e1000 \
                --import \
                --check path_in_use=off \
                --noautoconsole

    ip_count=$(virsh domifaddr $VMNAME | grep ipv4 | wc -l)
    echo -n "Waiting for machine to boot ."
    while [ $ip_count -ne 1 ]; do
        echo -n " ."
        sleep 1
        ip_count=$(virsh domifaddr $VMNAME | grep ipv4 | wc -l)
    done
    echo ""
    ip=$(virsh domifaddr $VMNAME | awk '{if ($3 == "ipv4") print $4;}'|cut -d'/' -f1)
    ssh-keyscan -H -t rsa ubuntu@$ip >> ~/.ssh/known_hosts
    echo "Virtual server $VMNAME is ready at $ip!"
    echo "You can log in the instance with:"
    echo "ssh ubuntu@$ip"
fi

