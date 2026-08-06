# NixOS Proxmox-like Virtualization Cluster

This repository defines a NixOS configuration that replicates core Proxmox VE features using Incus, ZFS, and FRR+EVPN. It is designed to run on a single hypervisor today and scale to a multi-host cluster by cloning the configuration to additional NixOS hosts.

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
│    │   Overlay fabric (enabled)   │    │
│    │  ├─ br-tenant-a  (VNI 10)    │    │
│    │  ├─ br-tenant-b  (VNI 20)    │    │
│    │  └─ ... more VNIs            │    │
│    └──────────────┬───────────────┘    │
│                   │                      │
│            ┌──────┴──────┐             │
│            │  vxlan10   │             │
│            │  vxlan20   │             │
│            │(FRR+EVPN)  │             │
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
- **ZFS** provides local storage, copy-on-write volumes for VMs/LXC, and automated snapshots.
- **FRR + EVPN** provides a multi-host L2 overlay fabric with two tenant segments already active. BGP peers are empty until a second hypervisor joins.
- **Ceph RBD** provides distributed block storage via a single-node Ceph cluster (MON, MGR, OSD on a 20G ZFS zvol). RBD images can be used for VM disks.
- **nftables** provides IPv4/IPv6 firewalling, both for the host and the overlay network.

---

## Module Breakdown

| File | Purpose |
|------|---------|
| [`configuration.nix`](configuration.nix) | Top-level configuration; imports all modules and hardware scan |
| [`hardware-configuration.nix`](hardware-configuration.nix) | Auto-generated disk/ZFS layout (do not edit) |
| [`modules/virtualization.nix`](modules/virtualization.nix) | Incus (KVM+LXC+UI), kernel sysctl for forwarding |
| [`modules/networking.nix`](modules/networking.nix) | systemd-networkd, VLAN/bond support, nftables firewall |
| [`modules/backup.nix`](modules/backup.nix) | ZFS auto-snapshots, syncoid for remote replication |
| [`modules/overlay-network.nix`](modules/overlay-network.nix) | Multi-host L2 overlay: FRR+BGP/EVPN, multi-VNI, kernel VXLAN |
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
| `incusbr0` | Bridge | `10.0.100.0/24` + `fd42:100::/64` | Yes | Default Incus network (VMs/LXC get IPs here) |
| `br-tenant-a` | Bridge | Overlay L2 (VNI 10) | N/A | Tenant A segment, 10.10.0.0/16 |
| `br-tenant-b` | Bridge | Overlay L2 (VNI 20) | N/A | Tenant B segment, 10.20.0.0/16 |

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

# Add custom bridge profiles for overlay segments
incus profile create tenant-a
incus profile device add tenant-a eth0 nic nictype=bridged parent=br-tenant-a name=eth0
incus launch images:debian/12 vm-a --vm --profile tenant-a

incus profile create tenant-b
incus profile device add tenant-b eth0 nic nictype=bridged parent=br-tenant-b name=eth0
incus launch images:debian/12 vm-b --vm --profile tenant-b

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
- **Overlay rules:** defined in `modules/overlay-network.nix`
  - Identical on every hypervisor → **distributed firewall**
  - Custom rules can be added via `networking.overlayNetwork.firewall.customRules`

---

## Backup & Snapshots

### ZFS Auto-Snapshots
| Interval | Retention | Timer |
|----------|-----------|-------|
| 15 minutes | 4 copies | `zfs-snapshot-frequent.timer` |
| Hourly | 24 copies | `zfs-snapshot-hourly.timer` |
| Daily | 7 copies | `zfs-snapshot-daily.timer` |
| Weekly | 4 copies | `zfs-snapshot-weekly.timer` |
| Monthly | 12 copies | `zfs-snapshot-monthly.timer` |

### Remote Replication (syncoid)
Configured but **disabled by default** in `modules/backup.nix`.

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
- Mount a remote snapshot locally: `zfs send ... | zfs recv zroot/restore`
- Access files under the snapshot path: `/zroot/restore/.zfs/snapshot/...`

---

## Multi-Host Overlay (FRR + BGP/EVPN)

The overlay network is **enabled** on this host with two tenant segments for local isolation. BGP has no peers yet — cross-host stretching activates automatically when you add a second hypervisor to `frrPeers`.

### What it does
When enabled, it creates one or more isolated overlay segments. Each segment gets:
- `vxlan<VNI>` — a kernel VXLAN tunnel interface (e.g. `vxlan10`, `vxlan20`)
- `br-<name>` — a Linux bridge that VMs and LXC attach to for that segment
- **FRR bgpd** — exchanges EVPN routes for *all* VNIs so every hypervisor learns which remote VTEP owns which MAC address in each segment

This makes VMs and containers on Host A reachable from VMs and containers on Host B as if they were on the same physical switch. Segments are fully isolated from each other at L2 — they are separate VNIs, not 802.1q VLANs on a shared wire.

### Current configuration
In `configuration.nix`:

```nix
networking.overlayNetwork = {
  enable = true;
  localAddress = "172.16.3.4";
  frrPeers = [];  # empty until second hypervisor joins
  frrAsn = 64512;
  vnis = [
    { vni = 10; bridgeName = "br-tenant-a"; overlaySubnet = "10.10.0.0/16"; }
    { vni = 20; bridgeName = "br-tenant-b"; overlaySubnet = "10.20.0.0/16"; }
  ];
  firewall.enable = true;
};
```

To add a second hypervisor, just put its underlay IP in `frrPeers` on both hosts and rebuild.

You can add more segments later by appending to `vnis` and rebuilding. Existing VNIs keep working because FRR advertises all of them.

### Scaling to many hosts

| Cluster Size | Topology | Config |
|--------------|----------|--------|
| 2–10 | Full mesh | Each host lists all others in `frrPeers` |
| 10–20 | Full mesh (tedious) or early RRs | Same, or promote 2 hosts to RRs |
| 20+ | **Route Reflectors** | 2–3 RRs carry full peer list; regular hosts only peer with RRs |

#### Route Reflector example
```nix
# On the RR host (e.g. 172.16.3.10)
networking.overlayNetwork = {
  enable = true;
  localAddress = "172.16.3.10";
  frrPeers = [ "172.16.3.11" "172.16.3.1" "172.16.3.2" /* ... all clients ... */ ];
  frrRouteReflectorClients = [ "172.16.3.1" "172.16.3.2" /* ... all clients ... */ ];
  frrAsn = 64512;
  vnis = [
    { vni = 10; bridgeName = "br-tenant-a"; overlaySubnet = "10.10.0.0/16"; }
    { vni = 20; bridgeName = "br-tenant-b"; overlaySubnet = "10.20.0.0/16"; }
  ];
};

# On a regular hypervisor (e.g. 172.16.3.5)
networking.overlayNetwork = {
  enable = true;
  localAddress = "172.16.3.5";
  frrPeers = [ "172.16.3.10" "172.16.3.11" ];  # only the RRs
  frrAsn = 64512;
  vnis = [
    { vni = 10; bridgeName = "br-tenant-a"; overlaySubnet = "10.10.0.0/16"; }
    { vni = 20; bridgeName = "br-tenant-b"; overlaySubnet = "10.20.0.0/16"; }
  ];
};
```

Adding Host 21 only requires editing **Host 21's** config and adding it to the RR client lists. No rebuilds on existing hosts.

### OVN (enabled — replaces the bridge workaround)

**Update:** OVN is now fully working on this host. See the [OVN SDN](#ovn-sdn) section below. The hand-written `ovn-northd`/`ovn-controller` systemd services live in `modules/ovn.nix`. OVN enables **project-scoped networks** — something the plain-bridge tenant model could not do.

---

## OVN SDN

OVN (Open Virtual Network) provides software-defined networking on top of Open vSwitch. It replaces the manual bridge-per-segment model with **logical networks that can be created per-project by tenants**.

### Components

| Service | Purpose | Provided by |
|---------|---------|-------------|
| `ovsdb` + `ovs-vswitchd` | Open vSwitch base | NixOS `virtualisation.vswitch.enable` |
| `ovn-nb-db` | OVN Northbound DB (logical topology) | `modules/ovn.nix` |
| `ovn-sb-db` | OVN Southbound DB (runtime state) | `modules/ovn.nix` |
| `ovn-northd` | Syncs NB → SB | `modules/ovn.nix` |
| `ovn-controller` | Local agent on each hypervisor | `modules/ovn.nix` |

### How it was wired up

1. `virtualisation.vswitch.enable = true` starts OVS.
2. `ovn-nb-db`/`ovn-sb-db` create databases with `ovsdb-tool create` using the OVN schemas, then serve them on unix sockets `/run/ovn/ovnnb_db.sock` and `/run/ovn/ovnsb_db.sock`.
3. `ovn-northd` connects NB ↔ SB.
4. `ovn-controller` connects to OVS and the SB DB, registers itself as a chassis (system-id = machine-id), and applies logical flows.
5. Incus config: `network.ovn.northbound_connection` and `network.ovn.integration_bridge` (set via preseed).

### Gotcha: OVN vs NixOS run-directory prefix

The `ovn` nixpkgs package is compiled with a `/usr/local` prefix, so `ovn-controller` looks for OVS sockets in `/usr/local/var/run/openvswitch/`. NixOS's vswitch module puts them in `/run/openvswitch/`. A tmpfiles symlink bridges the gap:

```nix
systemd.tmpfiles.rules = [
  "L+ /usr/local/var/run/openvswitch - - - - /run/openvswitch"
];
```

Without this, `ovn-controller` can't reach `br-int.mgmt` and won't claim logical ports (containers get no DHCP address).

### Usage

**Uplink network** — the OVN networks NAT through an existing managed network (here `incusbr0`). The uplink needs IP ranges reserved for OVN:

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

## Tenant Self-Managed Virtual Networks

Tenants have two paths to self-managed networking:

1. **OVN networks** (recommended) — project-scoped `--type=ovn` networks give each tenant their own logical switch + router with DHCP/NAT built in. No extra VMs needed. See [OVN SDN](#ovn-sdn).
2. **Virtual router appliance** — a self-managed OpenWrt/OPNsense VM for tenants who want full control of VLANs, firewall zones, and site-to-site VPN beyond what OVN provides.

Both can coexist; OVN handles the common case (isolated tenant subnets with NAT), the appliance handles power users.

### Virtual Appliance architecture

For tenants who need **their own internal networks** (VLANs, subnets, NAT, site-to-site VPN) beyond OVN, the recommended approach is a **self-managed virtual router appliance** inside their Incus project. Overlay segments like `br-tenant-a` and `br-tenant-b` are **isolated L2 domains** — VMs on one cannot reach VMs on the other by design.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        HYPERVISOR FABRIC                     │
│  ┌──────────────────┐              ┌──────────────────┐       │
│  │ br-tenant-a      │              │ br-tenant-b      │       │
│  │ 10.10.0.0/16     │              │ 10.20.0.0/16     │       │
│  │ VNI 10           │              │ VNI 20           │       │
│  └────────┬─────────┘              └────────┬─────────┘       │
│           │                                │                 │
│           └────────────┬───────────────────┘                 │
│                        │                                     │
│           ┌────────────▼─────────────┐                      │
│           │  Tenant Router VM         │                      │
│           │  (OpenWrt / OPNsense)     │                      │
│           │                           │                      │
│           │   eth0  ──► uplink to br-tenant-a                │
│           │   eth1  ──► uplink to br-tenant-b (optional)    │
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
│       Incus nets    managed by the tenant inside their VM   │
└─────────────────────────────────────────────────────────────┘
```

### Who manages what

| Layer | Platform Admin (You) | Tenant |
|-------|----------------------|--------|
| VXLAN / EVPN underlay | ✅ VNIs, bridges, BGP peers | ❌ |
| Physical host | ✅ ZFS, Ceph, Incus daemon | ❌ |
| Tenant project + quotas | ✅ `incus project create` | ❌ |
| Uplink attachment to overlay | ✅ `incus config device add` to `br-tenant-*` | ❌ |
| Router VM image | ✅ Provide `images:openwrt/23.05` | ❌ |
| Internal VLANs / subnets | ❌ | ✅ Inside their router VM |
| Firewall / NAT / VPN | ❌ | ✅ OpenWrt/OPNsense GUI |
| Downstream VM networks | ❌ | ✅ Incus bridge networks inside their project |
| VM lifecycle | ❌ | ✅ `incus launch` inside their project |

### Quick start: provision a tenant router

**1. Admin creates the project**

```bash
TENANT=alpha
incus project create $TENANT
incus project set $TENANT features.networks=true features.images=true
incus project set $TENANT limits.instances=20 limits.memory=64GiB
```

**2. Admin creates the router VM with overlay uplink(s)**

A pre-defined `router` profile sets 2 vCPUs, 256 MiB RAM, Secure Boot disabled, and a 2 GB Ceph root disk — perfect for OpenWrt.

```bash
incus init images:openwrt/23.05 $TENANT-router --project $TENANT \
  --profile router --vm

# Primary uplink to br-tenant-a
incus config device add $TENANT-router eth0 nic \
  nictype=bridged parent=br-tenant-a --project $TENANT

# Optional second uplink (e.g. for DMZ or multi-site)
# incus config device add $TENANT-router eth1 nic \
#   nictype=bridged parent=br-tenant-b --project $TENANT

incus start $TENANT-router --project $TENANT
```

**3. Tenant configures OpenWrt**

```bash
# Open a console on the router VM
incus exec $TENANT-router --project $TENANT -- ash
```

Inside the VM (OpenWrt/OPNsense/Linux):

- Assign `eth0` an IP on the overlay segment (e.g. `10.10.0.254/16`) — this becomes the **default gateway** for the tenant's VMs on that segment.
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

1. **Admin stays out of tenant routing.** The overlay fabric is pure L2 transport. No tenant firewall rules pollute the host nftables.
2. **Tenant gets full control.** VLANs, subnets, NAT, QoS, VPN — whatever they need, inside their own VM.
3. **Portable.** The router VM is just another Ceph RBD image. If the tenant moves to another hypervisor, the VM moves with them; uplink to the new host's `br-tenant-*` bridge and they're back online.
4. **Familiar tooling.** OpenWrt LUCI or OPNsense web UI is a much gentler learning curve than host-level nftables or FRR.
5. **Snapshot the whole network.** Snapshot the router VM before a config change. Rollback in seconds if you break NAT rules.

### Variation: Linux router instead of OpenWrt

For tenants who prefer plain Linux, use the same `router` profile but bump memory:

```bash
incus init images:ubuntu/24.04 $TENANT-router --project $TENANT \
  --profile router --vm
incus config set $TENANT-router limits.memory=1GiB --project $TENANT

# Same NIC attachments as OpenWrt example above
# Inside the VM:
#   apt install frr nftables kea dhcp4-server
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
systemctl is-active incus nftables systemd-networkd frr

# List Incus resources
incus storage list
incus network list
incus profile list

# ZFS status
zpool status
zfs list -t snapshot

# Ceph status
sudo ceph -s

# BGP status (when overlay enabled)
sudo vtysh -c "show bgp l2vpn evpn summary"
sudo vtysh -c "show bgp l2vpn evpn"
```

---

## Security Notes

- **Incus UI has no password auth.** Access is via TLS client certificates only.
- **Firewall is nftables.** Do not enable `networking.firewall.backend = "iptables"` — Incus will refuse to start.
- **Overlay firewall rules are identical on every host** because they are declared in Nix. This is the "distributed firewall" — there is no runtime agent pushing rules; the Nix expression is the source of truth.
- **ZFS encryption credentials** are requested at boot if datasets are encrypted.

---

## Future Roadmap

Items tracked in `/root/desired.txt` that are not yet implemented:
- QinQ (double-tagged VLANs)
- VXLAN tunneling without EVPN (not needed; we use FRR+EVPN)
- BGP-based EVPN (implemented; active locally, needs `frrPeers` for cross-host)
- Distributed firewall (implemented as identical nftables configs)
- Single-file restore from remote ZFS snapshots (documented workflow)
- ACME/Let's Encrypt for Incus UI (needs DNS-01 capable DNS server)
- Ceph multi-node expansion (currently single-node only)

---

## License

This configuration is specific to this NixOS installation. Adapt as needed for your own hosts.
