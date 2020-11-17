# Readme adn help

This is a facility to make even easier the creation of VMs in the daily
workflow. You can easily manage your virsh networks and create VMs faster than
you would do with continers.

## How to use

This is tested in ubuntu bionic

### KVM scrits

- cd into the kvm folder and run 'setup_kvm_tools.sh'
  That will install all dependencies and configure your environment
- run spawn-vm with the desired arguments, e.g.:
  spawn-vm --name generic --vcpus 1 --mem 2048 --disk 30 --series bionic
- Instance password is 'tijolo22'
