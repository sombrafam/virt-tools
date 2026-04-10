# virt-tools

Utilities for quickly creating and managing KVM virtual machines and LXD
containers in a local development workflow. Tested on Ubuntu jammy and noble.

## 1. KVM Virtual Machines

### Setup

Run once on the host to install dependencies and configure the environment:

```sh
cd kvm
./setup_kvm_tools.sh
```

### Spawning a VM

```sh
spawn-vm --name <name> --vcpus <n> --mem <mb> --disk <gb> --series <series>
```

**Options:**

| Flag | Description | Default |
|---|---|---|
| `--name` | VM name (required) | — |
| `--vcpus` | Number of vCPUs | 2 |
| `--mem` | Memory in MB | 2048 |
| `--disk` | Disk size in GB | 20 |
| `--series` | Ubuntu series (trusty/xenial/bionic/focal/jammy/noble) | focal |
| `--networks` | Comma-separated `name:id` pairs for multi-NIC setups | — |
| `--maas` | Enable MAAS PXE boot mode | — |
| `--network-prefix` | MAC address prefix | `52:54:00` |

**Example:**

```sh
spawn-vm --name dev --vcpus 2 --mem 4096 --disk 60 --series noble
```

The default user inside the VM is `ubuntu` (password: `tijolo22`).
Your `~/internal_git` directory is NFS-mounted inside the VM at
`/home/ubuntu/internal_git`.

---

## 2. LXD Containers

### Setup (run once per machine)

`lxd/setup-lxd-profile.sh` is self-contained and handles everything:

```sh
./lxd/setup-lxd-profile.sh
```

It will:

1. Install the LXD snap (channel `5/stable`) if not already present
2. Add your user to the `lxd` group
3. Activate the group for the current session (no re-login required)
4. Run `lxd init --auto` to initialise LXD with a default bridge, if needed
5. Configure UID/GID mapping so your user ID is preserved inside containers
6. Generate a dedicated SSH key (`~/.ssh/id_lxd_$USER`) and add it to
   `~/.ssh/authorized_keys` for passwordless login with a mounted `$HOME`
7. Create an LXD profile named after your username (`$USER`) that:
   - Mounts your `$HOME` directory into the container at the same path
   - Creates your user inside the container with sudo privileges
   - Connects the container to the active LXD bridge

### Spawning a Container

```sh
./lxd/spawn-container.sh <name> --series <series>
```

**Options:**

| Flag | Description | Default |
|---|---|---|
| `--series` | Ubuntu series | focal |

**Supported series:** trusty, xenial, bionic, focal, hirsute, impish, jammy, noble

**Example:**

```sh
./lxd/spawn-container.sh mycontainer --series jammy
```

The container will be named `<name>-<series>` (e.g., `mycontainer-jammy`),
launched with `--profile $USER`, and you will be dropped into a shell
as your own user once the UID mapping is ready.

---

## 3. Advanced: MAAS Lab

### Setting up KVM

```sh
kvm/setup_kvm_tools.sh
```

### Creating Networks for MAAS

```sh
cd kvm/networks
./create_networks.sh --external-interface eth0 --prefix 10.10 --bridges oam:10,admin:20,external:30
```

**Options:**

| Flag | Description |
|---|---|
| `-i, --external-interface` | Host interface for external access (required) |
| `-b, --bridges` | Bridged networks as `name:id` pairs |
| `-p, --prefix` | Network prefix (default: `10.10`) |
| `--use-vlans` | Configure VLANs on physical devices |

### Launch the MAAS Controller VM

```sh
./kvm/spawn-vm.sh --vcpus 4 --mem 8192 --disk 50 --series jammy \
    --networks oam:10,admin:20,external:30
```

Configure persistent addresses on the MAAS VM interfaces (typically
`x.y.10.2`, `x.y.20.2`, `x.y.30.2`). The VM needs internet access to
fetch the MAAS API key.

### Install MAAS Inside the VM

```sh
kvm/setup_maas.sh
```

This installs MAAS, initialises a region+rack controller, creates an admin
user (`admin`/`admin`), and saves the API key to `~/maas-apikey.txt`.

### Creating MAAS-managed VMs

```sh
spawn-vm --name maas-node1 --vcpus 2 --mem 4096 --disk 40 \
    --maas --networks public:30,admin:20,oam:10
```

Network XML templates are in `kvm/networks/`. Default networks:
`maas-admin`, `maas-public`, `maas-internal`.
