# NixOS Proxmox-like Virtualization Cluster

This repository defines a NixOS configuration that replicates core Proxmox VE features using Incus, OVN, ZFS, and Ceph RBD. It is designed to run on a single hypervisor today and scale to a multi-host cluster (3 OVN central + N compute nodes) by cloning the configuration to additional NixOS hosts.

## Host

| Property | Value |
|----------|-------|
| Hostname | `nixos` |
| Uplink | `ens18` → `172.16.3.4/24` |
| Root pool | `zroot` (127 GB, ZFS) |
| State version | `26.05` |

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│            NixOS Host (172.16.3.4)      │
│  ┌─────────────────────────────────┐   │
│  │            Incus                │   │
│  │  ├─ KVM VMs                     │   │
│  │  └─ LXC                         │   │
│  │      Web UI:8443                │   │
│  └─────────────┬───────────────────┘   │
│                │                        │
│    ┌───────────┴──────────┐             │
│    │      incusbr0       │             │
│    │    10.0.100.0/24    │             │
│    │    fd42:100::/64    │             │
│    └───────────┬──────────┘             │
│                │                        │
│         ┌──────┴──────┐                 │
│         │   ens18     │                 │
│         │172.16.3.4/24│                │
│         └─────────────┘                 │
│                                          │
│    ┌──────────────────────────────┐    │
│    │   OVN SDN (enabled)          │    │
│    │  ├─ NB/SB DBs (central)      │    │
│    │  ├─ ovn-northd               │    │
│    │  └─ ovn-controller (chassis) │    │
│    └──────────────┬───────────────┘    │
│                   │                      │
│            ┌──────┴──────┐             │
│            │   br-int    │             │
│            │ (OVS integ) │             │
│            │ geneve      │             │
│            └─────────────┘             │
│                                          │
│    ┌──────────────────────────────┐    │
│    │   Ceph RBD (single-node)     │    │
│    │  ├─ MON + MGR + OSD         │    │
│    │  └─ zroot/ceph-osd0 (20G)   │    │
│    └──────────────────────────────┘    │
└─────────────────────────────────────────┘
```

- **Incus** provides KVM virtual machines, Linux containers (LXC), and a web-based management UI.
- **OVN** provides the multi-host SDN fabric: project-scoped logical networks with DHCP/NAT, replacing the old FRR+EVPN overlay.
- **ZFS** is the encrypted host filesystem (`aes-256-gcm`). It holds the OS datasets, the swap zvol (`zroot/swap`), and the `zroot/ceph-osd0` zvol that backs the Ceph OSD. It does **not** store VM/LXC data — Incus uses Ceph RBD exclusively for that. ZFS auto-snapshots protect host state only.
- **Ceph RBD** provides distributed block storage via a single-node Ceph cluster (MON, MGR, OSD on a 20G ZFS zvol). **All Incus instances (VMs and LXC) store their root disks here.**
- **nftables** provides IPv4/IPv6 firewalling for the host.

---

## Module Breakdown

| File | Purpose |
|------|---------|
| [`configuration.nix`](configuration.nix) | Top-level configuration; imports all modules and hardware scan |
| [`hardware-configuration.nix`](hardware-configuration.nix) | Auto-generated disk/ZFS layout (do not edit) |
| [`modules/virtualization.nix`](modules/virtualization.nix) | Incus (KVM+LXC+UI), kernel sysctl for forwarding |
| [`modules/networking.nix`](modules/networking.nix) | systemd-networkd, VLAN/bond support, nftables firewall |
| [`modules/backup.nix`](modules/backup.nix) | ZFS auto-snapshots, syncoid for remote replication |
| [`modules/ovn.nix`](modules/ovn.nix) | OVN SDN: NB/SB databases, ovn-northd, ovn-controller (central/compute roles) |
| [`modules/users.nix`](modules/users.nix) | Admin user with `incus-admin`, `wheel` groups |
| [`modules/ceph.nix`](modules/ceph.nix) | Single-node Ceph cluster (MON+MGR+OSD) with RBD pool on ZFS zvol |

---

## Incus

### Storage
| Pool | Driver | Backing | Purpose |
|------|--------|---------|---------|
| `ceph` | Ceph RBD | `zroot/ceph-osd0` (Ceph OSD) | Distributed block storage; images clone from base layer |

Created automatically by Incus preseed on first boot or rebuild. The default profile uses this pool. The legacy ZFS pool has been removed.

### Networks
| Name | Type | Subnet | NAT | Purpose |
|------|------|--------|-----|---------|
| `incusbr0` | Bridge | `10.0.100.0/24` + `fd42:100::/64` | Yes | Default Incus network (VMs/LXC get IPs here), OVN uplink |
| `<tenant>-net` | OVN | auto (per project) | Yes | Project-scoped logical networks via OVN |
| `br-int` | OVS | N/A | N/A | OVN integration bridge (internal, managed by OVS) |

Project-scoped OVN networks are created on demand:

```bash
incus project create tenant-a
incus network create tenant-a-net --type=ovn --project tenant-a
```

### Web UI
- URL: `https://<host-ip>:8443`
- Authentication: **TLS client certificates only** (no passwords)
- To generate a login token:
  ```bash
  sudo incus config trust add my-workstation
  ```
  Paste the token into the browser UI.

### Console
- Incus VMs and LXC containers can be accessed via:
  - **Web UI** (HTML5/SPICE)
  - **CLI:** `incus console <name>`
- `virt-viewer` is installed for SPICE-based local console access.

### Quick start
```bash
# Create a VM (root disk on Ceph RBD)
incus launch images:debian/12 my-vm --vm

# Create an LXC container (root disk on Ceph RBD)
incus launch images:alpine/3.20 my-ct

# Create a project with an isolated OVN network
incus project create tenant-a
incus project set tenant-a features.networks=true
incus network create tenant-a-net --type=ovn --project tenant-a
incus launch images:debian/12 vm-a --project tenant-a --network tenant-a-net

# Create a standalone RBD image
sudo rbd create my-disk --size 10G --pool rbd
sudo rbd info my-disk --pool rbd
```

---

## Firewall

- **Backend:** `nftables` (required by Incus)
- **Host rules:** defined in `modules/networking.nix`
  - SSH (22) and Incus UI (8443) are open
  - Forwarding is allowed for bridges
- **OVN ACLs:** tenant network access control is handled natively by OVN logical ACLs rather than host nftables rules — keeping the host firewall minimal.

---

## Backup & Snapshots

> **Two separate backup domains** — don't confuse them:
> - **Host state** (OS datasets, Ceph OSD backing store): ZFS auto-snapshots + syncoid below.
> - **VM/LXC data** (all on Ceph RBD): incremental RBD backups to S3 — see [RBD Backups](#rbd-backups-incremental-to-s3-nas-zero-local-staging).

### ZFS Auto-Snapshots
Snapshot host datasets (`zroot/root`, `zroot/nix`, `zroot/ceph-osd0`) on the intervals below. These protect the NixOS system and the Ceph OSD backing store — **not** VM/container disks (those live in RBD and are handled by the RBD backup job).

| Interval | Retention | Timer |
|----------|-----------|-------|
| 15 minutes | 4 copies | `zfs-snapshot-frequent.timer` |
| Hourly | 24 copies | `zfs-snapshot-hourly.timer` |
| Daily | 7 copies | `zfs-snapshot-daily.timer` |
| Weekly | 4 copies | `zfs-snapshot-weekly.timer` |
| Monthly | 12 copies | `zfs-snapshot-monthly.timer` |

### Remote Replication (syncoid)
Configured but **disabled by default** in `modules/backup.nix`. Replicates the same host datasets (above) to a remote ZFS host — again, host state, not VM disks.

To enable:
1. Set up SSH key-based access to a remote ZFS host
2. Edit `modules/backup.nix`:
   ```nix
   services.syncoid = {
     enable = true;
     commands = {
       "zroot/root".target = "backup-server:zroot/backups/nixos/root";
     };
     sshKey = "/var/lib/syncoid/ssh.key";
   };
   ```
3. `nixos-rebuild switch`

### Single-file restore
Applies to host files from the ZFS snapshots above:
- Mount a remote snapshot locally: `zfs send ... | zfs recv zroot/restore`
- Access files under the snapshot path: `/zroot/restore/.zfs/snapshot/...`

For **VM/container files**, restore the RBD image from S3 (see the [RBD restore workflow](#rbd-backups-incremental-to-s3-nas-zero-local-staging)) and mount/`qemu-nbd` it locally.

---

## Multi-Host Networking (OVN)

OVN (Open Virtual Network) is the SDN layer for this fabric. It replaces the earlier FRR + BGP/EVPN overlay — which has been **removed** — because OVN provides everything EVPN did plus project-scoped logical networks, DHCP/NAT, and tenant self-service.

### Why OVN over FRR+EVPN

| Capability | FRR+EVPN (removed) | OVN |
|-----------|-------------------|-----|
| Cross-host L2 | VXLAN + BGP EVPN | Geneve tunnels (on-demand) |
| Tenant isolation | VNI per segment | Logical switch per project |
| DHCP / NAT | Not built in | Built in |
| Tenant self-service | Admin provisions bridges | `incus network create --type=ovn` |
| Control plane | BGP (peer management) | OVN NB/SB databases (RAFT) |

### Components

| Service | Purpose | Runs on |
|---------|---------|---------|
| `ovsdb` + `ovs-vswitchd` | Open vSwitch base | Every host |
| `ovn-nb-db` | OVN Northbound DB (logical topology) | Central (3 nodes) |
| `ovn-sb-db` | OVN Southbound DB (runtime state) | Central (3 nodes) |
| `ovn-northd` | Syncs NB → SB | Central (3 nodes) |
| `ovn-controller` | Local agent, registers chassis | Every host |

### Roles

`modules/ovn.nix` defines two roles:

- **`central`** — runs the NB/SB databases and `ovn-northd`. Use on the **first 3 hosts**. With 3 central nodes the databases form a RAFT cluster (quorum survives 1 failure). With 1 node the DBs run standalone (no HA).
- **`compute`** — runs only OVS + `ovn-controller`. Use on all other hosts.

### Current configuration (single host)

```nix
networking.ovn = {
  enable = true;
  role = "central";
  centralNodes = [ "172.16.3.4" ];   # 1 node = standalone DBs
  nodeIndex = 0;
  localAddress = "172.16.3.4";       # underlay IP (geneve encap)
};
```

### Scaling to 3 central + 27 compute hosts

| Host | Config |
|------|--------|
| Central 1 (172.16.3.1) | `role = "central"`, `centralNodes = ["172.16.3.1" "172.16.3.2" "172.16.3.3"]`, `nodeIndex = 0` |
| Central 2 (172.16.3.2) | same list, `nodeIndex = 1` |
| Central 3 (172.16.3.3) | same list, `nodeIndex = 2` |
| Compute 4..30 | `role = "compute"`, same `centralNodes` list |

All nodes use the same `centralNodes` list. Compute nodes connect their `ovn-controller` to the SB DBs (`tcp:<central>:6642`); central nodes additionally serve the DBs and run `ovn-northd`.

**Ports used:** 6641 NB client, 6642 SB client, 6643 NB RAFT, 6644 SB RAFT.

### Gotcha: OVN vs NixOS run-directory prefix

The `ovn` nixpkgs package is compiled with a `/usr/local` prefix, so `ovn-controller` looks for OVS sockets in `/usr/local/var/run/openvswitch/`. NixOS's vswitch module puts them in `/run/openvswitch/`. A tmpfiles symlink bridges the gap:

```nix
systemd.tmpfiles.rules = [
  "L+ /usr/local/var/run/openvswitch - - - - /run/openvswitch"
];
```

Without this, `ovn-controller` can't reach `br-int.mgmt` and won't claim logical ports (containers get no DHCP address).

### Usage

**Uplink network** — OVN networks NAT through an existing managed network (here `incusbr0`). The uplink needs IP ranges reserved for OVN:

```bash
incus network set incusbr0 ipv4.dhcp.ranges=10.0.100.100-10.0.100.200
incus network set incusbr0 ipv4.ovn.ranges=10.0.100.201-10.0.100.250
```

**Project-scoped OVN network** — the key win over bridges:

```bash
incus project create tenant-a
incus project set tenant-a features.networks=true
incus network create tenant-net --type=ovn --project tenant-a
incus launch alpine tenant-a-c1 --project tenant-a --network tenant-net
```

Each project gets its own logical switch + router, with DHCP, NAT, and (optionally) ACLs managed entirely by OVN.

---

## Incus Clustering (multi-host control plane)

**Current state: standalone.** This host is not part of an Incus cluster (`incus cluster list` → “Server isn't part of a cluster”). The config is prepared for clustering; joining is a **one-time imperative step**.

Clustering spans three independent layers that must all be in place:

| Layer | Mechanism | Status |
|-------|-----------|--------|
| Control plane | Incus embedded dqlite DB replicated via RAFT | Configured (`cluster.https_address`); join is imperative |
| Storage | Ceph RBD pool shared across members | Ready (`ceph` pool in preseed) — but single-node Ceph = no storage HA |
| Networking | OVN logical networks (cluster-wide) | Ready — see [Multi-Host Networking (OVN)](#multi-host-networking-ovn) |

### What's already declared in the config

```nix
# modules/virtualization.nix — identical on every member except the IP
preseed.config = {
  "core.https_address" = ":8443";
  "cluster.https_address" = "172.16.3.4:8443";   # this node's underlay IP
  "network.ovn.northbound_connection" = "tcp:172.16.3.4:6641";
  "network.ovn.integration_bridge" = "br-int";
};
```

Each new host clones the config and sets `cluster.https_address` to **its own** underlay IP. Wildcard addresses (`:8443`) are rejected by Incus for cluster traffic — a concrete address is required.

### Why the join is imperative (and survives reboots)

Cluster membership is persisted in `/var/lib/incus/database` (the dqlite/RAFT store) on the persistent ZFS root — **reboots never require re-joining**.

The join **must** stay imperative because the NixOS preseed is re-applied on **every boot** (`incus-preseed.service` is `WantedBy=incus.service`):

- Joining nodes need a **single-use join token** generated by the existing cluster
- The token is consumed on first join
- If the preseed contained the cluster section, the next boot would retry with a dead token and fail

So: declarative pins the stable endpoint, imperative performs the one-time join.

### Bootstrap procedure

```bash
# Node 1 (seed) — upgrade the already-initialized server to a cluster:
incus admin init          # answer "cluster? yes", give this node a name

# On node 1 — generate a join token for the new member:
incus cluster add node2   # prints one-time token

# On node 2 — paste the token (answers member_config questions interactively):
incus cluster join node2 <token>
```

Afterwards verify from any member:

```bash
incus cluster list
```

### Gotchas

- **Preseed only re-applies on incus start.** After editing `virtualisation.incus.preseed`, run `systemctl restart incus-preseed.service` — a plain rebuild won't re-trigger it.
- **The preseed is idempotent.** On a cluster member it re-applies config/pools/networks/profiles and skips existing ones — storage pools and profiles are **cluster-scoped** (created once, shared), while managed bridge networks like `incusbr0` are **per-member** (each host keeps its own L2).
- **Minimum 3 members for HA.** Incus uses RAFT for its internal DB; with 3 members it tolerates 1 failure. 2 members gives no quorum under failure.
- **Storage HA requires a real Ceph cluster.** Clustering Incus on the current single-node Ceph gives control-plane HA only — RBD images still live on one host. Add ≥3 OSDs with replication before trusting critical workloads.
- **Instance placement.** With shared RBD + OVN networks, `incus move` / `incus cluster group` relocate instances between members; OVN networks follow the instance automatically (no per-host wiring).

---

## Tenant Self-Managed Virtual Networks

Tenants have two paths to self-managed networking:

1. **OVN networks** (recommended) — project-scoped `--type=ovn` networks give each tenant their own logical switch + router with DHCP/NAT built in. No extra VMs needed. See [OVN SDN](#ovn-sdn).
2. **Virtual router appliance** — a self-managed OpenWrt/OPNsense VM for tenants who want full control of VLANs, firewall zones, and site-to-site VPN beyond what OVN provides.

Both can coexist; OVN handles the common case (isolated tenant subnets with NAT), the appliance handles power users.

### Virtual Appliance architecture

For tenants who need **their own internal networks** (VLANs, subnets, NAT, site-to-site VPN) beyond OVN, the recommended approach is a **self-managed virtual router appliance** inside their Incus project. Tenant OVN networks are isolated L2 domains — VMs on one cannot reach VMs on another without a router.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        HYPERVISOR FABRIC                     │
│  ┌──────────────────┐              ┌──────────────────┐       │
│  │ tenant-a-net     │              │ tenant-b-net     │       │
│  │ (OVN, per-proj)  │              │ (OVN, per-proj)  │       │
│  │ DHCP+NAT         │              │ DHCP+NAT         │       │
│  └────────┬─────────┘              └────────┬─────────┘       │
│           │                                │                 │
│           └────────────┬───────────────────┘                 │
│                        │                                     │
│           ┌────────────▼─────────────┐                      │
│           │  Tenant Router VM         │                      │
│           │  (OpenWrt / OPNsense)     │                      │
│           │                           │                      │
│           │   eth0  ──► uplink to OVN network (WAN)        │
│           │   eth1  ──► uplink to tenant internal net      │
│           │                           │                      │
│           │   ┌─────────────────────┐ │                      │
│           │   │  Inside the VM:     │ │                      │
│           │   │  • VLAN 10: Web     │ │                      │
│           │   │  • VLAN 20: DB      │ │                      │
│           │   │  • VLAN 30: Mgmt    │ │                      │
│           │   │  • WireGuard VPN    │ │                      │
│           │   │  • Firewall zones   │ │                      │
│           │   └─────────────────────┘ │                      │
│           └───────────────────────────┘                      │
│                        │                                     │
│           ┌────────────┼────────────┐                        │
│           ▼            ▼            ▼                        │
│      [alpha-web] [alpha-db] [alpha-dmz]                   │
│       tenant nets     managed by the tenant inside their VM │
└─────────────────────────────────────────────────────────────┘
```

> **Note:** With OVN available, most tenants don't need a router VM — they can use `--type=ovn` project networks (DHCP/NAT/ACLs built in). The appliance is for tenants who need full L3 control beyond what OVN offers.

### Who manages what

| Layer | Platform Admin (You) | Tenant |
|-------|----------------------|--------|
| OVN underlay | ✅ Central DBs, controllers | ❌ |
| Physical host | ✅ ZFS, Ceph, Incus daemon | ❌ |
| Tenant project + quotas | ✅ `incus project create` | ❌ |
| OVN network in project | ✅ `incus network create --type=ovn` | ✅ (if granted) |
| Router VM image | ✅ Provide `images:openwrt/23.05` | ❌ |
| Internal VLANs / subnets | ❌ | ✅ Inside their router VM |
| Firewall / NAT / VPN | ❌ | ✅ OpenWrt/OPNsense GUI |
| Downstream VM networks | ❌ | ✅ OVN networks or local bridges in their project |
| VM lifecycle | ❌ | ✅ `incus launch` inside their project |

### Quick start: provision a tenant router

**1. Admin creates the project**

```bash
TENANT=alpha
incus project create $TENANT
incus project set $TENANT features.networks=true features.images=true
incus project set $TENANT limits.instances=20 limits.memory=64GiB
```

**2. Admin creates the router VM with OVN uplink(s)**

A pre-defined `router` profile sets 2 vCPUs, 256 MiB RAM, Secure Boot disabled, and a 2 GB Ceph root disk — perfect for OpenWrt.

```bash
incus init images:openwrt/23.05 $TENANT-router --project $TENANT \
  --profile router --vm

# Primary uplink to a tenant OVN network (WAN)
incus config device add $TENANT-router eth0 nic \
  network=$TENANT-net --project $TENANT

# Optional second uplink to another tenant network
# incus config device add $TENANT-router eth1 nic \
#   network=$TENANT-dmz --project $TENANT

incus start $TENANT-router --project $TENANT
```

**3. Tenant configures OpenWrt**

```bash
# Open a console on the router VM
incus exec $TENANT-router --project $TENANT -- ash
```

Inside the VM (OpenWrt/OPNsense/Linux):

- Assign `eth0` an IP on the tenant's OVN network (e.g. `10.0.0.254/24`) — this becomes the **default gateway** for the tenant's VMs on that network.
- Create **VLAN interfaces** on `eth0` if you want micro-segmentation (`eth0.100`, `eth0.200`).
- Enable `net.ipv4.ip_forward=1`.
- Set up **firewall zones** (WAN = eth0, LAN = internal bridges).
- Run **DHCP + DNS** with dnsmasq for each internal network.
- Optionally run **WireGuard / OpenVPN** for remote access or site-to-site.

**4. Tenant creates internal networks and VMs**

```bash
# Inside the tenant's project
incus network create alpha-web  --project alpha
incus network create alpha-db   --project alpha

incus launch images:ubuntu/24.04 web1 --project alpha --network alpha-web
incus launch images:ubuntu/24.04 db1  --project alpha --network alpha-db
```

If the tenant used **macvtap** or **routed** NICs instead of bridges, the router VM handles all L3 — the downstream VMs use the router as their gateway without needing separate Incus networks.

### Why this model is ideal

1. **Admin stays out of tenant routing.** OVN handles L2+L3+NAT per project. No tenant firewall rules pollute the host nftables.
2. **Tenant gets full control.** VLANs, subnets, NAT, QoS, VPN — whatever they need, inside their own VM.
3. **Portable.** The router VM is just another Ceph RBD image. If the tenant moves to another hypervisor, the VM moves with them; its OVN network uplinks are already available cluster-wide.
4. **Familiar tooling.** OpenWrt LUCI or OPNsense web UI is a much gentler learning curve than host-level nftables or OVS commands.
5. **Snapshot the whole network.** Snapshot the router VM before a config change. Rollback in seconds if you break NAT rules.

### Variation: Linux router instead of OpenWrt

For tenants who prefer plain Linux, use the same `router` profile but bump memory:

```bash
incus init images:ubuntu/24.04 $TENANT-router --project $TENANT \
  --profile router --vm
incus config set $TENANT-router limits.memory=1GiB --project $TENANT

# Same NIC attachments as OpenWrt example above
# Inside the VM:
#   apt install nftables kea dhcp4-server
#   Configure as a standard Linux router with your choice of tooling
```

### Advanced variation: OVS-based SDN container

For power users who need OpenFlow, traffic mirroring, or custom tunneling, see the discussion in the code comments. This requires a **privileged container** with `security.nesting=true` and `security.syscalls.intercept.mknod=true` so the tenant can run Open vSwitch inside their project.

---

## Ceph RBD

A single-node Ceph cluster is running with a 20G OSD backed by the ZFS zvol `zroot/ceph-osd0`.

| Daemon | Status | Purpose |
|--------|--------|---------|
| `ceph-mon-a` | Active | Cluster monitor and quorum |
| `ceph-mgr-a` | Active | Manager (dashboard, metrics) |
| `ceph-osd-0` | Active | Object storage daemon on ZFS zvol |

### Pool
| Name | Application | PGs | Purpose |
|------|-------------|-----|---------|
| `rbd` | `rbd` | 32 | RADOS Block Device images |
| `.mgr` | `mgr` | 1 | Internal manager pool |

### Incus integration
Incus has a `ceph` storage pool (`driver: ceph`) backed by the `rbd` Ceph pool. The `ceph` profile uses this pool for VM and container root disks. Incus creates RBD images automatically — base images are stored as read-only snapshots, and instances are thin-cloned from them.

```bash
# List Incus storage pools
incus storage list

# Show Ceph pool config
incus storage show ceph

# Launch container on Ceph RBD
incus launch images:ubuntu/24.04 my-ct --profile ceph

# The container's root disk is an RBD image
sudo rbd ls --pool rbd | grep container_my-ct
```

### RBD quick commands
```bash
# Cluster status
sudo ceph -s

# List pools
sudo ceph osd pool ls

# Create a standalone image
sudo rbd create my-disk --size 10G --pool rbd

# List images
sudo rbd ls --pool rbd

# Image details
sudo rbd info my-disk --pool rbd

# Map to local block device
sudo rbd map my-disk --pool rbd
```

### Single-node tuning
The cluster is tuned for a single OSD:
- `osd_pool_default_size = 1` (no replication)
- `osd_pool_default_min_size = 1`
- Crush rule modified to use `type osd` instead of `type host`
- `mon_warn_on_pool_no_redundancy = false`

> **Note:** This is a single-node test cluster. Do not store critical data without adding more OSDs and enabling replication.

---

## RBD Backups (Incremental to S3 NAS, Zero Local Staging)

A systemd timer runs daily at 02:00 to back up all RBD images incrementally to an S3-compatible NAS via `rclone`. **No data is written to local disk** — the stream flows directly from Ceph → zstd → S3 upload.

### How it works
1. **First run**: `rbd export -` (stdout) → `zstd -19 -c` → `rclone rcat` uploads full image to S3
2. **Subsequent runs**: `rbd export-diff --from-snap <last> -` → `zstd -19 -c` → `rclone rcat` uploads delta
3. **RBD snapshots**: each backup creates a `backup-YYYYMMDD-HHMMSS` snapshot on the image (required for the next incremental diff)
4. **Retention**: keeps 7 RBD snapshots and 30 days of S3 backups

### Important: S3 single-put limit
`rclone` is configured with `RCLONE_S3_UPLOAD_CUTOFF=5G` so it streams via a single PUT up to the S3 API limit of 5 GB. Incremental diffs are almost always well under this. If a full export of a very large VM exceeds 5 GB, `rclone` may fall back to multipart buffering with temporary files.

### Setup (sops-nix)
Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix). The encrypted secrets file is tracked in git; only the age **private key** (on the host at `/var/lib/sops/age.key`) can decrypt it.

**1. Edit the encrypted secrets file:**
```bash
cd /etc/nixos
sops secrets/secrets.yaml
```
> If `sops` fails to find the age key, either export `SOPS_AGE_KEY_FILE=/var/lib/sops/age.key` or symlink it:
> ```bash
> mkdir -p ~/.config/sops/age
> ln -s /var/lib/sops/age.key ~/.config/sops/age/keys.txt
> ```
Replace the placeholder values under `rbdBackupS3Env` with your real NAS credentials, then save and exit.

The file should look like this (sops will encrypt it on save):

```yaml
rbdBackupS3Env: |
  RCLONE_CONFIG_S3NAS_TYPE=s3
  RCLONE_CONFIG_S3NAS_PROVIDER=Minio
  RCLONE_CONFIG_S3NAS_ENDPOINT=http://nas-ip:9000
  RCLONE_CONFIG_S3NAS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
  RCLONE_CONFIG_S3NAS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**2. Verify decryption works:**
```bash
sudo systemctl restart sops-nix
sudo cat /run/secrets/rbdBackupS3Env
```

**3. (One-time host setup)** The age private key was generated at `/var/lib/sops/age.key`. This file is **not in git** and must be preserved across reinstalls.

If you ever need to add a new host, generate a new age key and update `.sops.yaml`:
```bash
age-keygen -o /var/lib/sops/age-newhost.key
# Add the public key to .sops.yaml creation_rules
sops updatekeys secrets/secrets.yaml
```

### Manual run
```bash
sudo systemctl start rbd-backup.service
sudo journalctl -u rbd-backup.service -f
```

### S3 layout
```
rbd-backups/
└── rbd/
    ├── container_my-vm/
    │   ├── container_my-vm-20260806-020000.zst          (full)
    │   └── container_my-vm-20260807-020000.diff.zst    (incremental)
    └── virtual-machine_another-vm/
        └── ...
```

### Restore workflow
```bash
# 1. Download the base full backup
rclone copy s3nas:rbd-backups/rbd/container_my-vm/container_my-vm-YYYYMMDD-HHMMSS.zst .

# 2. Download each incremental diff in order
rclone copy s3nas:rbd-backups/rbd/container_my-vm/container_my-vm-YYYYMMDD-HHMMSS.diff.zst .

# 3. Create a new empty RBD image
sudo rbd create my-vm-restored --size 10G --pool rbd

# 4. Import full base
zstd -d container_my-vm-YYYYMMDD-HHMMSS.zst -c | sudo rbd import-diff - rbd/my-vm-restored

# 5. Replay each incremental
zstd -d container_my-vm-YYYYMMDD-HHMMSS.diff.zst -c | sudo rbd import-diff - rbd/my-vm-restored
```

---

## Quick Commands

```bash
# Rebuild the system
sudo nixos-rebuild switch

# Check all services
systemctl is-active incus nftables systemd-networkd ovn-northd

# List Incus resources
incus storage list
incus network list
incus profile list

# ZFS status
zpool status
zfs list -t snapshot

# Ceph status
sudo ceph -s

# OVN status
sudo systemctl status ovn-northd ovn-controller
```

---

## Security Notes

- **Incus UI has no password auth.** Access is via TLS client certificates only.
- **Firewall is nftables.** Do not enable `networking.firewall.backend = "iptables"` — Incus will refuse to start.
- **OVN ACLs** provide tenant network isolation natively (per logical network), keeping host nftables rules minimal.
- **ZFS encryption credentials** are requested at boot if datasets are encrypted.

---

## Future Roadmap

Items tracked in `/root/desired.txt` that are not yet implemented:
- QinQ (double-tagged VLANs)
- OVN multi-central-node RAFT cluster (module supports it; needs 3 hosts to activate)
- Incus control-plane clustering (config prepared; join not yet performed — see [Incus Clustering](#incus-clustering-multi-host-control-plane))
- Distributed firewall via OVN ACLs (native, per-project)
- Automated single-file restore from remote ZFS snapshots
- ACME/Let's Encrypt for Incus UI (needs DNS-01 capable DNS server)
- Ceph multi-node expansion (currently single-node only)

---

## License

This configuration is specific to this NixOS installation. Adapt as needed for your own hosts.
