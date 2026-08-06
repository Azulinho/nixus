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
- **Pool:** `default` on `zroot/incus` (ZFS, zvols for VMs, datasets for LXC)
- **Created automatically** by `incus-zfs-prep.service` on first boot.

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
# Create a VM
incus launch images:debian/12 my-vm --vm

# Create an LXC container
incus launch images:alpine/3.20 my-ct

# Add custom bridge profiles for overlay segments (when enabled)
incus profile create tenant-a
incus profile device add tenant-a eth0 nic nictype=bridged parent=br-tenant-a name=eth0
incus launch images:debian/12 vm-a --vm --profile tenant-a

incus profile create tenant-b
incus profile device add tenant-b eth0 nic nictype=bridged parent=br-tenant-b name=eth0
incus launch images:debian/12 vm-b --vm --profile tenant-b

# Create an RBD image (block storage)
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
       "zroot/incus".target = "backup-server:zroot/backups/nixos/incus";
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

### Why not OVN?
NixOS has no `ovn-northd` or `ovn-controller` module. Using OVN would require hand-writing ~5 systemd services and manually integrating them with Incus. FRR+EVPN is fully supported in nixpkgs and achieves the same stretched-L2 result.

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

### RBD quick commands
```bash
# Cluster status
sudo ceph -s

# List pools
sudo ceph osd pool ls

# Create an image
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
