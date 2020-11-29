#!/bin/bash -xe

# Install base packages
sudo apt-get install -y virtinst cloud-image-utils libvirt-clients \
  nfs-kernel-server libvirt-bin

# Create required folders
mkdir -p "${HOME}/VMScripts"
mkdir -p "${HOME}/VMStorage/Images"
mkdir -p "${HOME}/VMStorage/Disks"
mkdir -p "${HOME}/bin"

# Download base images
echo "Downloading base images"
if [ ! -f  ${HOME}/VMStorage/Images/trusty-server-cloudimg-amd64-disk1.img ]; then
    wget https://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-disk1.img -P "${HOME}/VMStorage/Images"
fi

if [ ! -f  ${HOME}/VMStorage/Images/xenial-server-cloudimg-amd64-disk1.img ]; then
    wget https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img -P "${HOME}/VMStorage/Images"
fi

if [ ! -f  ${HOME}/VMStorage/Images/bionic-server-cloudimg-amd64.img ]; then
    wget https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.img -P "${HOME}/VMStorage/Images"
fi

if [ ! -f  ${HOME}/VMStorage/Images/focal-server-cloudimg-amd64.img ]; then
    wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -P "${HOME}/VMStorage/Images"
fi

# Setup ssh keys
if [ ! -f  ${HOME}/.ssh/id_rsa.pub ]; then
    ssh-keygen -b 2048 -t rsa -q -N "" -f "${HOME}/.ssh/id_rsa"
fi

rm -rf ${HOME}/bin/spawn-vm
ln -s "$(dirname $0)/spawn-vm.sh" "${HOME}/bin/spawn-vm"

export PATH=$PATH:${HOME}/bin
echo "PATH=\$PATH:${HOME}/bin" >> ${HOME}/.bashrc

# Configure cloud init template
LOCAL_USER_KEY=$(cat ${HOME}/.ssh/id_rsa.pub)

# This shared folder must be shared through NFS in the host. Access should be
# given to the sub-network the VMs will receive IP.
SHARED_FOLDER__NAME="internal_git"
mkdir -p ${HOME}/${SHARED_FOLDER__NAME}

grep "${HOME}/${SHARED_FOLDER__NAME}" /etc/exports || echo "${HOME}/${SHARED_FOLDER__NAME}  *(rw,sync,no_subtree_check,anonuid=1000,anongid=1000,all_squash)" \
  | sudo tee -a /etc/exports && sudo systemctl restart nfs-kernel-server

cat << EOF > ${HOME}/VMScripts/cloud-config-template
#cloud-config
# user password is: tijolo22
users:
  - name: ubuntu
    ssh-authorized-keys:
      - $LOCAL_USER_KEY
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
    passwd: \$6\$uHJKDSG68qu4WnSQ\$Jz13SwqtOPSRaLanTqYAlMdTpORMrzYl.tnGgGNSNBVmXDsv7/t2ibC3j2kC6/GGDMUKvBcbcX.ks2it1alKR0
    lock_passwd: false
package_update: true
packages:
  - nfs-common
runcmd:
   - [mkdir, -p, /home/ubuntu/$SHARED_FOLDER__NAME]
   - [chown, -R, ubuntu.ubuntu, /home/ubuntu/$SHARED_FOLDER__NAME]
   - [mount, "192.168.122.1:$HOME/$SHARED_FOLDER__NAME", /home/ubuntu/$SHARED_FOLDER__NAME]
write_files:
  - content: |
      192.168.122.1:$HOME/$SHARED_FOLDER__NAME /home/ubuntu/$SHARED_FOLDER__NAME nfs defaults 0 0
    path: /etc/fstab
    append: true
hostname: ubuntu

EOF
