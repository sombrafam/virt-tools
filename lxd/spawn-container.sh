#!/bin/bash

usage() {
    echo "Usage: $0 <container-name> [--series <trusty|xenial|bionic|focal|hirsute|impish|jammy>]"
}

if [ -z $1 ]; then
    usage
    exit 1
fi


while (($# > 0)); do
    case "$1" in
        --series)
            SERIES=$2
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            VMNAME=$1
            ;;
    esac
    shift
done


SERIES=${SERIES:-"focal"}
CWD=$(pwd)

lxc info "${VMNAME}-${SERIES}" &> /dev/null
if [[ $? -ne 0 ]]; then
    sudo lxc launch --profile erlon ubuntu:${SERIES} ${VMNAME}-${SERIES}
else
    echo "Container already exists"
fi

echo -n "Waiting for container to be mapped "
sudo lxc exec "${VMNAME}-${SERIES}" cat /etc/passwd | grep erlon &> /dev/null
while [ $? -ne 0 ]; do
    echo -n ". "
    sleep 0.5
    sudo lxc exec "${VMNAME}-${SERIES}" cat /etc/passwd | grep erlon &> /dev/null
done
echo "Done!"


sudo lxc exec ${VMNAME}-${SERIES} su - erlon
