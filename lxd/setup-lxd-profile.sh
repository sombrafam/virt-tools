#!/bin/bash -x
set -eu
_UID=$(id -u)
GID=$(id -g)

# Install LXD snap if not already installed
if ! snap list lxd &>/dev/null; then
    sudo snap install lxd --channel=5/stable
else
    sudo snap refresh lxd --channel=5/stable 2>/dev/null || true
fi

# Add current user to the lxd group if not already a member
if ! groups | grep -qw lxd; then
    sudo usermod -aG lxd "$USER"
    echo "Added $USER to lxd group. Activating group for this session..."
fi

# Activate lxd group in current shell without re-login
# Wrap lxc so all calls run with the lxd group active
lxc() { sg lxd -c "lxc $*"; }

# Initialise LXD with defaults if no bridge network exists yet
if ! lxc network list --format csv 2>/dev/null | awk -F, 'tolower($2)=="bridge"' | grep -q .; then
    sudo lxd init --auto
fi

LXD_BRIDGE_NAME=""
# Find the first active, managed LXD bridge network
for net_name in $(lxc network list --format csv | awk -F, 'tolower($2)=="bridge" && tolower($3)=="yes" {print $1}'); do
  # Ensure net_name is not empty before querying its state
  if [ -n "$net_name" ]; then
    # Check if the network status is 'Created'
    if lxc network show "$net_name" 2>/dev/null | grep -q "^status: Created$"; then
      LXD_BRIDGE_NAME="$net_name"
      break
    fi
  fi
done

if [ -z "$LXD_BRIDGE_NAME" ]; then
  echo "Error: Could not find an active, managed LXD bridge network. Please ensure one is set up and active." >&2
  exit 1
fi

# give lxd permission to map your user/group id through
grep root:$_UID:1 /etc/subuid -qs || sudo usermod --add-subuids ${_UID}-${_UID} --add-subgids ${GID}-${GID} root

# set up a separate key to make sure we can log in automatically via ssh
# with $HOME mounted
KEY=$HOME/.ssh/id_lxd_$USER
PUBKEY=$KEY.pub
AUTHORIZED_KEYS=$HOME/.ssh/authorized_keys

[ -f $PUBKEY ] || ssh-keygen -f $KEY -N '' -C "key for local lxds"
grep "$(cat $PUBKEY)" $AUTHORIZED_KEYS -qs || cat $PUBKEY >> $AUTHORIZED_KEYS

# create a profile to control this, name it after $USER
lxc profile delete $USER &> /dev/null || true
lxc profile create $USER &> /dev/null || true

# configure profile
# this will rewrite the whole profile
cat << EOF | lxc profile edit $USER
name: $USER
description: allow home dir mounting for $USER
config:
  # this part maps uid/gid on the host to the same on the container
  raw.idmap: |
    uid $_UID 1000
    gid $GID 1000
  # note: user.user-data is still available
  user.vendor-data: |
    #cloud-config
    users:
      - name: $USER
        groups: sudo
        shell: $SHELL
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
    # ensure users shell is installed
    packages:
      - bash
devices:
  eth0:
    name: eth0
    network: $LXD_BRIDGE_NAME
    type: nic
  root:
    path: /
    pool: default
    type: disk
# this section adds your \$HOME directory into the container. This is useful for vim, bash and ssh config, and such like.
  home:
    type: disk
    source: $HOME
    path: $HOME
EOF


# to launch a container using this profile:
# lxc launch ubuntu: -p default -p $USER

# to add an additional bind mount
# lxc config device add <container> <device name> disk source=/path/on/host path=path/in/container
