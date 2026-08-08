# NixOS Hypervisor Cluster — Operator's Manual

> **What this is:** this repository contains the complete, declarative NixOS
> configuration for a 3-node Proxmox-like virtualization cluster built on
> **Incus** (KVM + LXC), **OVN** (multi-host SDN), **ZFS** (encrypted host
> filesystem) and **Ceph RBD** (distributed instance storage).
>
> **Who this is for:** the owner/operator(s) who administer these hosts and the
> tenants who run workloads on them. It is written as a manual: read the
> [System Overview](#2-system-overview) first, then jump to the task you need
> ([Backup & Restore](#8-backup--restore), [Cluster Admin](#9-cluster-administration),
> [Tenants](#10-tenant-self-service)).
>
> **Conventions:** `$` = shell prompt (regular user), `#` = root or `sudo`.
> `nodeX` refers to one of the hypervisor hosts; commands that are
> cluster-wide are marked *any node*.

---

## Table of Contents

1. [Quick Reference](#1-quick-reference)
2. [System Overview](#2-system-overview)
3. [Configuration & Deployment Model](#3-configuration--deployment-model)
4. [Storage Model](#4-storage-model)
5. [Networking](#5-networking)
6. [Virtualization: Incus](#6-virtualization-incus)
7. [DNS & Name Resolution](#7-dns--name-resolution)
8. [Backup & Restore](#8-backup--restore)
9. [Cluster Administration](#9-cluster-administration)
10. [Tenant Self-Service](#10-tenant-self-service)
11. [Routine Maintenance](#11-routine-maintenance)
12. [Troubleshooting & Known Issues](#12-troubleshooting--known-issues)
13. [Security Notes](#13-security-notes)
14. [Roadmap & Known Gaps](#14-roadmap--known-gaps)
15. [Quick Command Reference](#15-quick-command-reference)
16. [License](#16-license)

---

## 1. Quick Reference

The three commands you will use most often, and where each subsystem lives:

| You want to… | Command / file |
|--------------|----------------|
| Change any configuration | edit this repo, then `sudo nixos-rebuild switch` (any node) |
| Say *which node am I* | `cat /etc/nixos/hostname` |
| Change per-host values (IP, nodeIndex, timezone…) | `local/settings.nix` → `hosts.<name>` |
| Create/start/stop instances | `incus launch`, `incus start`, `incus stop` (via `admin` user) |
| Open the management web UI | `https://<node-ip>:8443` (TLS client cert only) |
| Check VM/container storage health | `sudo ceph -s`, `incus storage list` |
| Check host filesystem health | `zpool status`, `zfs list -t snapshot` |
| Check nightly instance backups | `sudo journalctl -u rbd-backup.service -e` |
| Verify DNS for instances | `nslookup vm1.project1.incus-cluster1.mydomain` |

> **The single most important mental model:** host state (OS, snapshots, Ceph
> OSD backing store) lives on **ZFS**; *every* VM/container root disk lives on
> **Ceph RBD**. Backups mirror this split (see [§8](#8-backup--restore)).

---

## 2. System Overview

### 2.1 What this is

A 3-node hypervisor cluster that replicates the core features of Proxmox VE on
NixOS. Every node runs the identical software stack — Incus, OVN (central +
compute), and a shared, cluster-capable Ceph cluster on ZFS — so the configuration is
declarative and reproducible. The cluster scales to N nodes by cloning the
repository and adding an entry to `local/settings.nix`
(see [Scaling to N hosts](#91-adding-a-host-scaling-to-n)).

### 2.2 Cluster layout

Per-host values — hostname, underlay IP, `hostId`, time zone, uplink NIC — live
in `local/settings.nix` and are selected by the gitignored
`/etc/nixos/hostname` file (see [§3.2](#32-per-host-settings)).

| Host | Underlay IP | OVN role | Note |
|------|-------------|----------|------|
| z3-nix01 | 172.16.3.4 | central + compute | seeded first; `nodeIndex = 0` |
| node2 | 172.16.3.5 | central + compute | `nodeIndex = 1` |
| node3 | 172.16.3.6 | central + compute | `nodeIndex = 2` |

Root pool: `zroot` (127 GB, ZFS, encrypted) on every node. NixOS state version
`26.05`.

### 2.3 Architecture

```
┌─────────────────────────────────────────────┐
│              NixOS Host (z3-nix01)           │
│  ┌───────────────────────────────────────┐  │
│  │               Incus                   │  │
│  │   ├─ KVM VMs        Web UI :8443      │  │
│  │   └─ LXC                             │  │
│  └───────────────┬───────────────────────┘  │
│                  │                          │
│      ┌───────────┴───────────┐              │
│      │   incusbr0 (bridge)   │ 10.0.100.1/24│
│      │   NAT + dnsmasq       │ fd42:100::/64│
│      └───────────┬───────────┘              │
│                  │                          │
│           ┌──────┴──────┐                   │
│           │   ens18     │ 172.16.3.4/24     │
│           └─────────────┘                   │
│                                              │
│    ┌──────────────────────────────────────┐  │
│    │   OVN SDN (central + compute)        │  │
│    │   ├─ NB/SB databases (RAFT, 3 nodes) │  │
│    │   ├─ ovn-northd                      │  │
│    │   └─ ovn-controller (local chassis)  │  │
│    │   geneve tunnels over ens18          │  │
│    └──────────────────────────────────────┘  │
│                                              │
│    ┌──────────────────────────────────────┐  │
│    │   Ceph RBD (shared cluster)            │  │
│    │   ├─ MON + MGR + OSD                │  │
│    │   └─ OSD backed by zroot/ceph-osd0   │  │
│    └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

node2 and node3 run the identical layout (their own underlay IPs).

**Layer-by-layer:**

| Layer | Role in this cluster |
|-------|----------------------|
| **NixOS** | Declarative base: one repo, identical modules on every host |
| **Incus** | KVM VMs, LXC containers, web UI (`:8443`); preseeded declaratively |
| **OVN** | Multi-host SDN: project-scoped logical networks with DHCP/NAT, carried between hosts over geneve tunnels |
| **ZFS** | Encrypted host filesystem (`aes-256-gcm`): OS datasets, swap zvol, the `zroot/ceph-osd0` zvol that backs the Ceph OSD. **Does not** store instance data |
| **Ceph RBD** | Distributed block storage (one MON/MGR/OSD per node, single shared cluster, 20 G ZFS zvol each). **Every Incus instance root disk lives here** |
| **nftables** | IPv4/IPv6 host firewall |

### 2.4 Services & ports

| Port | Proto | Service | Open on |
|------|-------|---------|---------|
| 22 | TCP | SSH | all nodes |
| 8443 | TCP | Incus API / Web UI | all nodes |
| 3300, 6789 | TCP | Ceph msgr2 / msgr1 (clients + cluster) | all nodes |
| 6641 | TCP | OVN northbound DB (clients: incusd, ovn-northd, ovn-controller) | central nodes |
| 6642 | TCP | OVN southbound DB (clients: ovn-controller) | central nodes |
| 6643 | TCP | OVN NB RAFT (between centrals) | central nodes |
| 6644 | TCP | OVN SB RAFT (between centrals) | central nodes |
| 6081 | UDP | OVN geneve tunnels | all nodes |
| 53, 67, 547 | TCP/UDP | dnsmasq DNS + DHCP on `incusbr0` (10.0.100.1) | all nodes, interface-scoped |

Systemd units you will see on every node (see the [service inventory](#156-service-inventory) for the full list):

- `incus.service`, `incus-preseed.service`, `incus-dns-refresh.timer`
- `ovsdb.service` / `ovs-vswitchd` (Open vSwitch base)
- `ovn-nb-db`, `ovn-sb-db`, `ovn-northd`, `ovn-controller` (central role)
- `ceph-mon-<id>`, `ceph-mgr-<id>`, `ceph-osd-<id>` (per node: a/0, b/1, c/2) + bootstrap one-shots
- `rbd-backup.service` / `rbd-backup.timer` (nightly, 02:00)
- `zfs-snapshot-{frequent,hourly,daily,weekly,monthly}.timer`
- `systemd-networkd`, `sshd`, `nftables`

---

## 3. Configuration & Deployment Model

### 3.1 Repository layout

| File | Purpose |
|------|---------|
| `configuration.nix` | Top-level configuration; imports all modules, hardware scan, sops-nix, and derives per-host `settings` |
| `local/settings.nix` | **Per-host values as a `hosts` dictionary** (hostId, IPs, nodeIndex, timeZone, uplink NIC…) plus cluster-wide keys (`centralNodes`, `cephNodes`, `dnsZone`, `cephFsid`). Committed once, serves all hosts |
| `/etc/nixos/hostname` (gitignored) | One line: this host's name (e.g. `z3-nix01`) — selects the `hosts.<name>` entry |
| `local/<hostname>-hardware-configuration.nix` | Per-host hardware scan (`nixos-generate-config` output, do not edit by hand) — one file per node, all committed |
| `modules/virtualization.nix` | Incus (KVM + LXC + UI), preseed (pools, networks, profiles), kernel sysctls for forwarding, KSM |
| `modules/networking.nix` | systemd-networkd, VLAN/bond support, nftables firewall incl. OVN ports and DNS/DHCP on `incusbr0` |
| `modules/ovn.nix` | OVN SDN: NB/SB databases, ovn-northd, ovn-controller (central/compute roles, RAFT bootstrapping) |
| `modules/ceph.nix` | Shared Ceph cluster (MON+MGR+OSD per node) with RBD pool on ZFS zvols; 3-phase bootstrap/join; auto-tunes replication to topology |
| `scripts/ceph-init-keys.sh` | One-time generator for the shared Ceph keyrings (encrypts into sops) |
| `modules/rbd-backup.nix` | Incremental RBD backups to S3 via rclone (nightly timer, retention) |
| `modules/incus-dns.nix` | Per-project instance DNS records through the uplink dnsmasq |
| `modules/backup.nix` | ZFS auto-snapshots, syncoid remote replication (disabled by default) |
| `modules/users.nix` | Admin user with `incus-admin`, `wheel` groups |
| `.sops.yaml` / `secrets/secrets.yaml` | sops-nix key holders / encrypted secrets (S3 credentials, Ceph keyrings) |
| `.gitignore` | Excludes `result`, `hostname`, hardware scans before rename, age keys |

### 3.2 Per-host settings

`local/settings.nix` holds a `hosts` dictionary — one entry per node — plus
cluster-wide keys. `/etc/nixos/hostname` (gitignored, one line) picks the active
host. `configuration.nix` reads that name, merges `hosts.<name>` with the
cluster-wide keys, and exposes the result to every module as the `settings`
argument:

```nix
# local/settings.nix — committed once, serves all hosts
{
  hosts = {
    z3-nix01 = { hostId = "01234567"; localAddress = "172.16.3.4"; nodeIndex = 0;
              uplinkInterface = "ens18"; timeZone = "Europe/London"; };
    node2 = { hostId = "…"; localAddress = "172.16.3.5"; nodeIndex = 1;
              uplinkInterface = "ens18"; timeZone = "Europe/London"; };
    node3 = { hostId = "…"; localAddress = "172.16.3.6"; nodeIndex = 2;
              uplinkInterface = "ens18"; timeZone = "Europe/London"; };
  };
  centralNodes = [ "172.16.3.4" "172.16.3.5" "172.16.3.6" ];  # SAME on every host
  cephNodes    = [ "172.16.3.4" "172.16.3.5" "172.16.3.6" ];  # Ceph mon IPs (one mon per node)
  dnsZone = "incus-cluster1.mydomain";                        # fabric DNS zone
  cephFsid = "ede5176c-2777-4e6d-9cf1-529d4dfe0057";          # Ceph cluster identity
}

# /etc/nixos/hostname  (gitignored, one line per machine)
z3-nix01
```

`cluster.https_address`, the Ceph mon list (`cephNodes`) and
`network.ovn.northbound_connection` are all derived from `settings`, so cloning
a host is just: copy the repo → create `/etc/nixos/hostname` with the host's
name → generate and commit `local/<hostname>-hardware-configuration.nix` →
re-encrypt secrets for the new host's age key. Full procedure in
[§9.1](#91-adding-a-host-scaling-to-n).

> **Warning:** `hostId` must be **unique per host** (it seeds ZFS). Generate one
> with `genhostid` / `zgenhostid` before first boot.

### 3.3 Rebuilding & deploying

```bash
# Apply changes to the running system (any node)
sudo nixos-rebuild switch

# Diagnostics if a rebuild fails
sudo nixos-rebuild switch --show-trace

# Inspect what the current build contains
ls -l result
```

Changes are declared in this repo only — there is no imperative state to manage
on the hosts themselves except:

- the gitignored `/etc/nixos/hostname` (per-host identity),
- `/var/lib/sops/age.key` (age private key, see [§3.4](#34-secrets-sops-nix)),
- the one-time Incus cluster join (see [§9.2](#92-incus-control-plane-clustering)).

### 3.4 Secrets (sops-nix)

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix). The
encrypted secrets file is tracked in git; only the age **private key** on the
host (`/var/lib/sops/age.key`) can decrypt it. Currently only the RBD backup S3
credentials (`rbdBackupS3Env`) are stored this way.

**Editing secrets:**

```bash
cd /etc/nixos
sops secrets/secrets.yaml
```

> If `sops` can't find the age key, export `SOPS_AGE_KEY_FILE=/var/lib/sops/age.key`
> or symlink it:
> ```bash
> mkdir -p ~/.config/sops/age
> ln -s /var/lib/sops/age.key ~/.config/sops/age/keys.txt
> ```

The file looks like this (sops encrypts it on save):

```yaml
rbdBackupS3Env: |
  RCLONE_CONFIG_S3NAS_TYPE=s3
  RCLONE_CONFIG_S3NAS_PROVIDER=Minio
  RCLONE_CONFIG_S3NAS_ENDPOINT=http://nas-ip:9000
  RCLONE_CONFIG_S3NAS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
  RCLONE_CONFIG_S3NAS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**Verify decryption:**

```bash
sudo systemctl restart sops-nix
sudo cat /run/secrets/rbdBackupS3Env
```

**Adding a new host** — the file is encrypted to *all* hosts at once (one
committed `secrets.yaml`, no per-host copies). The key holders are listed in
`.sops.yaml`:

```bash
# 1. On the new host, get its age public key:
age-keygen -y /var/lib/sops/age.key

# 2. Add it to .sops.yaml (under `keys:` and in the `creation_rules` key group), then:
sops updatekeys secrets/secrets.yaml
```

`sops updatekeys` re-encrypts the file for every listed key — existing hosts
keep working, the new host can decrypt the same file with its own private key.

> **Backup-critical:** `/var/lib/sops/age.key` is **not in git** and must be
> preserved across reinstalls. Losing it = losing access to the secrets file.

---

## 4. Storage Model

There are **two storage domains** — do not confuse them:

| Domain | Backend | Holds | Backed up by |
|--------|---------|-------|--------------|
| **Host state** | ZFS `zroot` (encrypted) | OS datasets, swap zvol, Ceph OSD backing zvol | ZFS auto-snapshots + (optional) syncoid → [§8.2](#82-host-state-zfs-auto-snapshots) |
| **Instance data** | Ceph RBD | every VM and LXC root disk | incremental RBD backups to S3 → [§8.4](#84-restore-workflows) |

### 4.1 ZFS root pool

- Pool `zroot`, 127 GB, encrypted (`aes-256-gcm`), encryption credentials
  requested at boot (see [§13 Security](#13-security-notes)).
- Host datasets: OS root, `/nix`, swap zvol (`zroot/swap`), and the Ceph OSD
  backing store `zroot/ceph-osd0` (20 G zvol).
- **ZFS does not store instance data.** Auto-snapshots protect host state only.

### 4.2 Ceph RBD

**One shared Ceph cluster** for the whole Incus fleet, built by the same
module on every node: each host runs its own MON/MGR/OSD (`mon a/b/c`,
`osd 0/1/2`) against the same cluster — same fsid, same monmap, same
keyrings (see below). It works as a single node today and grows to 3 nodes
by simply deploying the same config to the other hosts; no cluster rebuild.

| Daemon | Purpose |
|--------|---------|
| `ceph-mon-<a/b/c>` | Monitor + quorum (1 per node) |
| `ceph-mgr-<a/b/c>` | Manager (dashboard, metrics) |
| `ceph-osd-<0/1/2>` | OSD on that node's `zroot/ceph-osd0` zvol |

| Pool | Application | PGs | Purpose |
|------|-------------|-----|---------|
| `rbd` | `rbd` | 32 | RADOS Block Device images (all Incus root disks) |
| `.mgr` | `mgr` | 1 | Internal manager pool |

**Incus integration:** Incus has a `ceph` storage pool (`driver: ceph`, source
`rbd`). The `default` and `ceph` profiles use it for instance root disks. Incus
creates RBD images automatically — base images are stored as read-only
snapshots, and instances are thin-cloned from them.

```bash
# List Incus storage pools
incus storage list

# Show the Ceph pool config
incus storage show ceph

# A container's root disk is an RBD image
sudo rbd ls --pool rbd | grep container_my-ct
```

**Keyrings — generated once, shared via sops.** All nodes authenticate with
the same admin + mon keyrings (encrypted in `secrets/secrets.yaml`). First
deploy on z3-nix01:

```bash
sudo scripts/ceph-init-keys.sh             # generate + sops-encrypt the keyrings
git add secrets/secrets.yaml && git commit # distribute to the repo
sudo nixos-rebuild switch
```

When node2/node3 come online: add their age keys to `.sops.yaml`, run
`sops updatekeys secrets/secrets.yaml`, then deploy the same repo there.
Their phase1 bootstrap detects the live cluster and **joins** it (fetches
the monmap, adds itself, mkfs with the shared mon keyring) instead of
creating a new one.

**Automatic topology tuning (phase3, re-evaluated on every boot):**
- **1 OSD host** → single-node mode: `osd_pool_default_size = 1` (no
  replication), CRUSH rule uses `type osd`, no-redundancy warning off.
- **≥2 OSD hosts** → replicated mode: `rbd` pool `size 3` / `min_size 2`,
  CRUSH rule restored to `type host`, no-redundancy warning on. With exactly
  2 OSDs the pool is degraded but writable; it reaches `active+clean` when
  the third OSD lands.

> **Caveat:** until nodes 2/3 are deployed this is effectively a single-node
> cluster — a host failure takes its instances with it. Control-plane HA from
> OVN/Incus clustering does **not** make storage HA. See [§12.5](#125-ceph)
> for the growth recipe.

---

## 5. Networking

### 5.1 Host networking

`systemd-networkd` is the host network backend (NetworkManager is force-disabled
by `modules/networking.nix`). The uplink interface (per-host name from
`local/settings.nix`, e.g. `ens18`) is configured for DHCP + IPv6 RA.

VLAN and bonding support are compiled in but **inactive by default** — activate
the commented examples in `modules/networking.nix` if needed:

```nix
networking.vlans."ens18.100" = { id = 100; interface = "ens18"; };
networking.bonds."bond0" = { interfaces = [ "ens18" "ens19" ]; driverOptions = { mode = "802.3ad"; miimon = "100"; lacp_rate = "fast"; }; };
```

### 5.2 Firewall (nftables)

- **Backend:** `nftables` — required by Incus. Do **not** set
  `networking.firewall.backend = "iptables"`; Incus will refuse to start.
- **Host rules** (`modules/networking.nix`): SSH (22) and Incus UI (8443) open;
  OVN DB ports (6641–6644/TCP) on central nodes; geneve (6081/UDP) whenever OVN
  is enabled; ping allowed; forwarding allowed for bridges.
- **DNS/DHCP on `incusbr0`:** the firewall must accept DNS/DHCP arriving on the
  bridge, otherwise instance queries are dropped at INPUT before reaching
  dnsmasq. This is configured and is **critical on any new host**:

```nix
interfaces.incusbr0 = {
  allowedTCPPorts = [ 53 ];
  allowedUDPPorts = [ 53 67 547 ];
};
```

Without it: OVN/bridge instances cannot resolve anything (timeout), and bridge
instances never get a DHCPv4 lease.

- **Tenant network isolation** is handled natively by OVN logical ACLs, not host
  nftables rules — keeping the host firewall minimal.

### 5.3 Incus networks

| Name | Type | Subnet | NAT | Purpose |
|------|------|--------|-----|---------|
| `incusbr0` | Bridge | `10.0.100.0/24` + `fd42:100::/64` | Yes | Default Incus network (VMs/LXC get IPs here), OVN uplink |
| `<tenant>-net` | OVN | auto (per project) | Yes | Project-scoped logical networks via OVN |
| `br-int` | OVS | N/A | N/A | OVN integration bridge (internal, managed by OVS) |

**Uplink network** — OVN networks NAT through an existing managed network (here
`incusbr0`). The uplink needs IP ranges reserved for OVN:

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

Each project gets its own logical switch + router, with DHCP, NAT, and
(optionally) ACLs managed entirely by OVN. See [§10 Tenants](#10-tenant-self-service).

### 5.4 OVN SDN fabric

OVN (Open Virtual Network) is the SDN layer: project-scoped logical networks
with DHCP/NAT and tenant self-service, carried between hosts over **geneve**
tunnels.

| Service | Purpose | Runs on |
|---------|---------|---------|
| `ovsdb` + `ovs-vswitchd` | Open vSwitch base | every host |
| `ovn-nb-db` | OVN Northbound DB (logical topology) | central nodes |
| `ovn-sb-db` | OVN Southbound DB (runtime state) | central nodes |
| `ovn-northd` | Syncs NB → SB | central nodes |
| `ovn-controller` | Local agent, registers chassis | every host |

**Roles** (`modules/ovn.nix`):

- **`central`** — runs the NB/SB databases and `ovn-northd` **and** the local
  `ovn-controller` (the controller runs on every host regardless of role). A
  central node is therefore simultaneously a compute/hypervisor node. Use on
  the **first 3 hosts**: the databases form a RAFT cluster (quorum survives 1
  failure). With 1 node the DBs run standalone (no HA).
- **`compute`** — runs only OVS + `ovn-controller`. Use for 4th+ hypervisors.

**This cluster: z3-nix01, node2 and node3 are all `central`** — every node is both a
control-plane member and a hypervisor. All nodes use the same `centralNodes`
list; compute nodes connect their `ovn-controller` to the SB DBs
(`tcp:<central>:6642`).

**OVN vs NixOS run-directory prefix** — the `ovn` nixpkgs package is compiled
with a `/usr/local` prefix, so `ovn-controller` looks for OVS sockets in
`/usr/local/var/run/openvswitch/` while NixOS's vswitch module puts them in
`/run/openvswitch/`. A tmpfiles symlink bridges the gap (already configured in
`modules/ovn.nix`):

```nix
systemd.tmpfiles.rules = [
  "L+ /usr/local/var/run/openvswitch - - - - /run/openvswitch"
];
```

Without this, `ovn-controller` can't reach `br-int.mgmt` and won't claim
logical ports (containers get no DHCP address).

---

## 6. Virtualization: Incus

### 6.1 Management web UI

- URL: `https://<host-ip>:8443`
- Authentication: **TLS client certificates only** (no passwords)
- To generate a login token for your workstation:

```bash
sudo incus config trust add my-workstation
```

Paste the token into the browser UI.

### 6.2 Console access

- **Web UI** (HTML5/SPICE), **CLI:** `incus console <name>`
- `virt-viewer` is installed for SPICE-based local console access.

### 6.3 Storage pools & profiles

Defined by the Incus preseed in `modules/virtualization.nix` (re-applied on
every boot — [§9.2](#92-incus-control-plane-clustering) for the caveats):

| Pool | Driver | Backing | Purpose |
|------|--------|---------|---------|
| `ceph` | Ceph RBD | `rbd` pool (zvol-backed OSD) | Distributed block storage; instances clone from base-layer snapshots |

| Profile | Purpose |
|---------|---------|
| `default` | eth0 on `incusbr0`, root disk on `ceph` pool |
| `ceph` | same as default, explicit |
| `router` | Lightweight VM profile for tenant virtual routers (2 vCPU, 256 MiB, Secure Boot off, 2 GiB root on ceph) |

### 6.4 Quick start

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

## 7. DNS & Name Resolution

DNS in this stack is deliberately **one resolver for the whole fabric**: Incus
hands every network (bridge *and* OVN) DHCP option 6 = the uplink gateway
`10.0.100.1`, where the uplink dnsmasq answers. It recurses via
`systemd-resolved` (127.0.0.53) to the LAN router `172.16.3.1`.

### 7.1 Resolution layers

| Layer | What it does |
|-------|--------------|
| LAN router `172.16.3.1` | upstream recursion for the host (DHCP-assigned) |
| `systemd-resolved` | host resolver, stub at `127.0.0.53`; public fallbacks |
| uplink dnsmasq on `incusbr0` (`10.0.100.1:53`) | the resolver every instance points at: `.incus` domain, `_gateway.incus`, per-project records (`addn-hosts`), recursion upstream |
| OVN DHCP (ovn-northd) | hands out IP + **option 6** (nameserver `10.0.100.1`) + **option 15** (search domain, from `dns.search`) per network |

### 7.2 Per-project DNS

Incus 7.0.1 does **not** generate name→IP records for OVN instances (`dns.zone`
is rejected on OVN networks; `dns.mode` is inert with the dnsmasq backend).
`modules/incus-dns.nix` closes that gap:

- `services.incusDns.enable` + `services.incusDns.zone` — zone comes from
  `local/settings.nix` (`dnsZone`), enabled in `configuration.nix`
- `raw.dnsmasq = "addn-hosts=/run/incus-dns/hosts.d"` on `incusbr0` (preseed)
  hooks a hosts directory into the uplink dnsmasq
- `incus-dns-refresh.timer` (every 60 s) reads `incus list` per project and
  writes `IP <name>.<project>.<zone> <name>` per project, then SIGHUPs dnsmasq

Records are auto-discovered for **all** projects — no per-project config.
Cross-project resolution works automatically (one resolver holds every
project's zone).

**Opting a project out (private DNS):** mark it private and the refresh script
stops publishing it — its names resolve nowhere (NXDOMAIN), including from the
project's own instances:

```bash
incus project set project1 user.dns_private=true    # records stop being published
incus project unset project1 user.dns_private       # publish again
```

Privacy here means *non-discoverability*: DNS names are not a security boundary
(the real isolation is OVN L2/L3 segmentation + firewall). Two caveats:
instances on **bridge** networks are still auto-registered by Incus itself as
`<name>.incus` regardless of this flag, so private projects should use OVN
networks only; and the flag key is configurable via
`services.incusDns.privateFlag`.

**Per project, when creating its OVN network:**

```bash
incus project create project1 --config features.networks=true
incus network create project1-net --type=ovn --project project1
incus network set project1-net dns.search=project1.incus-cluster1.mydomain --project project1
incus launch images:alpine/edge vm1 --project project1 --network project1-net
```

Then inside any project1 instance:

```bash
nslookup vm2.project1.incus-cluster1.mydomain   # FQDN
nslookup vm2                                    # short name (search domain)
```

Both resolve; external names still recurse upstream. Verified live against
7.0.1.

### 7.3 Known DNS limits

- **`dns.zone` unsupported on OVN** in 7.0.1 — records must come from
  `incus-dns-refresh` (above)
- **Search domain is per network**, not per project — set it when creating each
  OVN network
- **No per-project DNS isolation** — the fabric resolver holds all projects'
  zones. True isolation would need per-project DNS servers plus per-network
  DHCP option 6 overrides, which 7.0.1 does not expose declaratively
- **Refresh lag** — records update within the 60 s timer tick (instant updates
  via `incus monitor` lifecycle events are a possible future upgrade)

---

## 8. Backup & Restore

> **Two separate backup domains — don't confuse them:**
> - **Host state** (OS datasets, Ceph OSD backing store): ZFS auto-snapshots +
>   syncoid (§8.2–8.3).
> - **VM/LXC data** (all on Ceph RBD): incremental RBD backups to S3 (§8.4).

### 8.1 RBD backup pipeline (how it works)

A systemd timer runs daily at **02:00** to back up all RBD images incrementally
to an S3-compatible NAS via `rclone`. **No data is written to local disk** —
the stream flows directly Ceph → zstd → S3 upload.

> **Designated runner.** `services.rbdBackup.designatedHost` (default
> `z3-nix01`) decides which node runs the backup. The RBD pool is shared by the
> whole cluster, so a timer on every node would upload identical backups
> repeatedly. The service and timer are only *defined* on the designated host
> (the script also guards at runtime).

1. **First run:** `rbd export -` (stdout) → `zstd -19 -c` → `rclone rcat`
   uploads full image to S3.
2. **Subsequent runs:** `rbd export-diff --from-snap <last> -` → `zstd -19 -c`
   → `rclone rcat` uploads delta.
3. **RBD snapshots:** each backup creates a `backup-YYYYMMDD-HHMMSS` snapshot on
   the image (required for the next incremental diff).
4. **Retention:** 7 RBD snapshots and 30 days of S3 backups are kept.

Configuration (in `configuration.nix` → `services.rbdBackup`):

| Option | Value |
|--------|-------|
| `pool` | `rbd` |
| `rcloneRemote` | `s3nas` |
| `s3BucketPrefix` | `rbd-backups` |
| `schedule` | `*-*-* 02:00:00` |
| `retentionSnapshots` / `retentionDays` | `7` / `30` |
| `compress` | `true` (zstd -19) |
| `credentialsFile` | `/run/secrets/rbdBackupS3Env` (sops-nix) |
| `imageFilter` | `^(container_\|virtual-machine_\|image_)` |

> **S3 single-put limit:** `rclone` is configured with
> `RCLONE_S3_UPLOAD_CUTOFF=5G` so it streams via a single PUT up to the S3 API
> limit of 5 GB. Incremental diffs are almost always well under this. If a full
> export of a very large VM exceeds 5 GB, `rclone` may fall back to multipart
> buffering with temporary files.

**Manual run / monitoring:**

```bash
sudo systemctl start rbd-backup.service
sudo journalctl -u rbd-backup.service -f
```

**S3 layout:**

```
rbd-backups/
└── rbd/
    ├── container_my-vm/
    │   ├── container_my-vm-20260806-020000.zst          (full)
    │   └── container_my-vm-20260807-020000.diff.zst    (incremental)
    └── virtual-machine_another-vm/
        └── ...
```

### 8.2 Host state: ZFS auto-snapshots

Snapshots are taken of host datasets carrying the `com.sun:auto-snapshot=true`
property (in this installation: `zroot/root`, `zroot/nix`, `zroot/ceph-osd0`).
The swap zvol is excluded (`zfs set com.sun:auto-snapshot=false zroot/swap`).
These protect the NixOS system and the Ceph OSD backing store — **not** VM/
container disks (those live in RBD, see §8.4).

| Interval | Retention | Timer |
|----------|-----------|-------|
| 15 minutes | 4 copies | `zfs-snapshot-frequent.timer` |
| Hourly | 24 copies | `zfs-snapshot-hourly.timer` |
| Daily | 7 copies | `zfs-snapshot-daily.timer` |
| Weekly | 4 copies | `zfs-snapshot-weekly.timer` |
| Monthly | 12 copies | `zfs-snapshot-monthly.timer` |

### 8.3 Host state: remote replication (syncoid)

Configured but **disabled by default** in `modules/backup.nix`. Replicates the
same host datasets to a remote ZFS host — again, host state, not VM disks.

To enable:

1. Set up SSH key-based access to a remote ZFS host.
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

3. `sudo nixos-rebuild switch`

### 8.4 Restore workflows

**Restore an RBD image from S3:**

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

**Single-file restore (host files from ZFS snapshots):**

- Mount a remote snapshot locally: `zfs send ... | zfs recv zroot/restore`
- Access files under the snapshot path: `/zroot/restore/.zfs/snapshot/...`

For **VM/container files**, restore the RBD image from S3 (above) and
mount/`qemu-nbd` it locally.

> **Recovery best practice:** restore a test VM from S3 at least monthly —
> backups that are never restored are just hopes.

---

## 9. Cluster Administration

### 9.1 Adding a host (scaling to N)

| Host | Setup |
|------|-------|
| z3-nix01 (172.16.3.4) | `/etc/nixos/hostname` → `z3-nix01` (entry: `localAddress = "172.16.3.4"`, `nodeIndex = 0`) |
| node2 (172.16.3.5) | `/etc/nixos/hostname` → `node2` (entry: `localAddress = "172.16.3.5"`, `nodeIndex = 1`) |
| node3 (172.16.3.6) | `/etc/nixos/hostname` → `node3` (entry: `localAddress = "172.16.3.6"`, `nodeIndex = 2`) |
| Compute 4..N | add a `hosts.<name>` entry in `local/settings.nix`, set `role = "compute"` in `configuration.nix` |

Full procedure for a new node:

```bash
# 1. On the new host: clone this repo to /etc/nixos, then
echo nodeX > /etc/nixos/hostname

# 2. Generate the hardware scan and commit it as local/<hostname>-hardware-configuration.nix
nixos-generate-config --dir /etc/nixos/local
mv /etc/nixos/local/hardware-configuration.nix /etc/nixos/local/nodeX-hardware-configuration.nix

# 3. Make sure local/settings.nix has a hosts.nodeX entry (copy an existing node)
# 4. Add the new host's age public key to .sops.yaml and re-encrypt secrets
age-keygen -y /var/lib/sops/age.key
sops updatekeys secrets/secrets.yaml

# 5. Build
sudo nixos-rebuild switch
```

All nodes use the same `centralNodes` list. Compute nodes connect their
`ovn-controller` to the SB DBs (`tcp:<central>:6642`); central nodes
additionally serve the DBs and run `ovn-northd`.

### 9.2 Incus control-plane clustering

**Current state: standalone.** This host is not yet part of an Incus cluster
(`incus cluster list` → “Server isn't part of a cluster”). The config is
prepared for clustering; joining is a **one-time imperative step**.

Clustering spans three independent layers that must all be in place:

| Layer | Mechanism | Status |
|-------|-----------|--------|
| Control plane | Incus embedded dqlite DB replicated via RAFT | Configured (`cluster.https_address`); join is imperative |
| Storage | Ceph RBD pool shared across members | Ready (`ceph` pool in preseed); shared cluster — add nodes 2/3 for storage HA |
| Networking | OVN logical networks (cluster-wide) | Ready — see [§5.4](#54-ovn-sdn-fabric) |

**What's already declared in the config** (identical on every member — no
per-node edits):

```nix
# modules/virtualization.nix
preseed.config = {
  "core.https_address" = ":8443";
  "cluster.https_address" = "${settings.localAddress}:8443";      # per-host
  "network.ovn.northbound_connection" = "tcp:${lib.elemAt settings.centralNodes 0}:6641";  # z3-nix01 (single NB remote)
  "network.ovn.integration_bridge" = "br-int";
};
```

Wildcard addresses (`:8443`) are rejected by Incus for cluster traffic — a
concrete address is required.

**Why the join is imperative (and survives reboots):**

Cluster membership is persisted in `/var/lib/incus/database` (the dqlite/RAFT
store) on the persistent ZFS root — **reboots never require re-joining**. The
join **must** stay imperative because the NixOS preseed is re-applied on
**every boot** (`incus-preseed.service` is `WantedBy=incus.service`):

- Joining nodes need a **single-use join token** generated by the existing cluster
- The token is consumed on first join
- If the preseed contained the cluster section, the next boot would retry with a
  dead token and fail

So: declarative pins the stable endpoint, imperative performs the one-time join.

**Bootstrap procedure:**

```bash
# z3-nix01 (seed) — initialize the cluster:
incus admin init          # answer "cluster? yes"; name this member "z3-nix01" (defaults to hostname)

# On z3-nix01 — generate a join token for the new member:
incus cluster add node2   # prints one-time token

# On node 2 — paste the token (answers member_config questions interactively):
incus cluster join node2 <token>
```

Afterwards verify from any member:

```bash
incus cluster list
```

**Gotchas:**

- **Preseed only re-applies on incus start.** After editing
  `virtualisation.incus.preseed`, run `systemctl restart incus-preseed.service`
  — a plain rebuild won't re-trigger it.
- **The preseed is idempotent.** On a cluster member it re-applies
  config/pools/networks/profiles and skips existing ones — storage pools and
  profiles are **cluster-scoped** (created once, shared), while managed bridge
  networks like `incusbr0` are **per-member** (each host keeps its own L2).
- **Minimum 3 members for HA.** Incus uses RAFT for its internal DB; with 3
  members it tolerates 1 failure. 2 members gives no quorum under failure.
- **Storage HA requires a replicated Ceph cluster.** Until node2/node3 are
  deployed the Ceph pool is size 1 — control-plane HA only, RBD images still
  live on one host. Deploy the other nodes (see §4.2) to get replicated
  storage before trusting critical workloads.
- **Instance placement.** With shared RBD + OVN networks, `incus move` /
  `incus cluster group` relocate instances between members; OVN networks follow
  the instance automatically (no per-host wiring).

### 9.3 OVN administration

Status and maintenance:

```bash
# Cluster/DB status
sudo systemctl status ovn-nb-db ovn-sb-db ovn-northd ovn-controller
sudo ovn-sbctl show            # chassis, logical ports
sudo ovn-nbctl show            # logical topology

# Chassis registration (system-id from /etc/machine-id)
sudo ovs-vsctl show
```

---

## 10. Tenant Self-Service

Tenants have two paths to self-managed networking:

1. **OVN networks** (recommended) — project-scoped `--type=ovn` networks give
   each tenant their own logical switch + router with DHCP/NAT built in. No
   extra VMs needed. See [§5.4](#54-ovn-sdn-fabric).
2. **Virtual router appliance** — a self-managed OpenWrt/OPNsense VM for
   tenants who want full control of VLANs, firewall zones, and site-to-site VPN
   beyond what OVN provides.

Both can coexist; OVN handles the common case (isolated tenant subnets with
NAT), the appliance handles power users.

### 10.1 Virtual router appliance architecture

For tenants who need **their own internal networks** (VLANs, subnets, NAT,
site-to-site VPN) beyond OVN, the recommended approach is a **self-managed
virtual router appliance** inside their Incus project. Tenant OVN networks are
isolated L2 domains — VMs on one cannot reach VMs on another without a router.

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
│           │   eth0 ──► OVN network (WAN)                    │
│           │   eth1 ──► tenant internal network              │
│           │   Inside the VM: VLANs, firewall zones,         │
│           │   WireGuard VPN, QoS — tenant-managed           │
│           └───────────────────────────┘                      │
│                        │                                     │
│           ┌────────────┼────────────┐                        │
│           ▼            ▼            ▼                        │
│      [alpha-web] [alpha-db] [alpha-dmz]                   │
│        tenant subnets managed inside their router VM        │
└─────────────────────────────────────────────────────────────┘
```

> **Note:** with OVN available, most tenants don't need a router VM — they can
> use `--type=ovn` project networks (DHCP/NAT/ACLs built in). The appliance is
> for tenants who need full L3 control beyond what OVN offers.

### 10.2 Who manages what

| Layer | Platform Admin (You) | Tenant |
|-------|----------------------|--------|
| OVN underlay | ✅ Central DBs, controllers | ❌ |
| Physical host | ✅ ZFS, Ceph, Incus daemon | ❌ |
| Tenant project + quotas | ✅ `incus project create` | ❌ |
| OVN network in project | ✅ `incus network create --type=ovn` | ✅ (if granted) |
| Router VM image | ✅ Provide `images:openwrt/23.05` | ❌ |
| Internal VLANs / subnets | ❌ | ✅ inside their router VM |
| Firewall / NAT / VPN | ❌ | ✅ OpenWrt/OPNsense GUI |
| Downstream VM networks | ❌ | ✅ OVN networks or local bridges in their project |
| VM lifecycle | ❌ | ✅ `incus launch` inside their project |

### 10.3 Quick start: provision a tenant router

**1. Admin creates the project**

```bash
TENANT=alpha
incus project create $TENANT
incus project set $TENANT features.networks=true features.images=true
incus project set $TENANT limits.instances=20 limits.memory=64GiB
```

**2. Admin creates the router VM with OVN uplink(s)**

A pre-defined `router` profile sets 2 vCPUs, 256 MiB RAM, Secure Boot disabled,
and a 2 GB Ceph root disk — perfect for OpenWrt.

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

- Assign `eth0` an IP on the tenant's OVN network (e.g. `10.0.0.254/24`) — this
  becomes the **default gateway** for the tenant's VMs on that network.
- Create **VLAN interfaces** on `eth0` if you want micro-segmentation
  (`eth0.100`, `eth0.200`).
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

If the tenant used **macvtap** or **routed** NICs instead of bridges, the
router VM handles all L3 — the downstream VMs use the router as their gateway
without needing separate Incus networks.

**Why this model is ideal**

1. **Admin stays out of tenant routing.** OVN handles L2+L3+NAT per project. No
   tenant firewall rules pollute the host nftables.
2. **Tenant gets full control.** VLANs, subnets, NAT, QoS, VPN — whatever they
   need, inside their own VM.
3. **Portable.** The router VM is just another Ceph RBD image. If the tenant
   moves to another hypervisor, the VM moves with them; its OVN network uplinks
   are already available cluster-wide.
4. **Familiar tooling.** OpenWrt LUCI or OPNsense web UI is a much gentler
   learning curve than host-level nftables or OVS commands.
5. **Snapshot the whole network.** Snapshot the router VM before a config
   change. Rollback in seconds if you break NAT rules.

**Variation: Linux router instead of OpenWrt**

```bash
incus init images:ubuntu/24.04 $TENANT-router --project $TENANT \
  --profile router --vm
incus config set $TENANT-router limits.memory=1GiB --project $TENANT

# Same NIC attachments as the OpenWrt example above.
# Inside the VM: apt install nftables kea dhcp4-server and configure
# a standard Linux router with your choice of tooling.
```

---

## 11. Routine Maintenance

A minimal operating rhythm for the cluster (adjust cadence to taste):

| When | What | Command |
|------|------|---------|
| **Daily** | Instance backups succeeded | `sudo journalctl -u rbd-backup.service -e` (look for `Backup complete`) |
| **Daily** | Storage & filesystem health | `sudo ceph -s` (expect HEALTH_OK), `zpool status`, `zfs list -t snapshot` |
| **Daily** | OVN fabric healthy | `sudo systemctl is-active ovn-northd ovn-controller` on each node |
| **Weekly** | Test a restore | restore a throwaway VM from S3 (§8.4) |
| **Weekly** | Disk space | `zpool list`, `df -h /`, check RBD usage `sudo rbd du --pool rbd` |
| **After every rebuild** | Preseed & services re-applied | `systemctl is-active incus nftables systemd-networkd ovn-northd`; restart `incus-preseed.service` if you changed the preseed |
| **Monthly** | Snapshots retention sane | `zfs list -t snapshot \| wc -l` (should be bounded by retention §8.2) |
| **Monthly** | Secrets round-trip | `sudo cat /run/secrets/rbdBackupS3Env` works after `systemctl restart sops-nix` |
| **On incident** | Everything | see [§12 Troubleshooting](#12-troubleshooting--known-issues) |

---

## 12. Troubleshooting & Known Issues

### 12.1 OVN

- **Standalone → RAFT migration.** The current DBs were bootstrapped standalone
  (`ovsdb-tool create`), and the pre-start script only bootstraps when
  `/var/lib/ovn/ovnnb.db` / `ovnsb.db` don't exist — editing `centralNodes`
  alone will **not** re-cluster them. To convert: stop OVN on all three hosts,
  delete both DB files on **all** hosts, then boot **z3-nix01 first** (runs
  `create-cluster`), then node2, then node3 (each runs `join-cluster`
  automatically).
- **Incus ↔ OVN NB is a single remote.** `network.ovn.northbound_connection`
  takes one address (z3-nix01). OVSDB RAFT redirect covers leader changes while
  z3-nix01 is reachable, but if z3-nix01 is fully down, incusd's OVN integration has
  no NB connection until it returns. (`ovn-northd`/`ovn-controller` are
  unaffected — they use the full comma-separated remote list.)
- **Bridge networks keep the same subnet on every member.** Incus does **not**
  split `ipv4.address=10.0.100.1/24` per member — verified in the v7.0.1
  source: the only member-specific network keys are
  `bridge.external_interfaces`, `parent`, `bgp.ipv4.nexthop`,
  `bgp.ipv6.nexthop` and `tunnel.*`, and cluster network creation applies the
  identical config on all members. So every node runs its own `incusbr0` with
  the same `10.0.100.1/24` behind NAT → **per-member L2 islands**: instances on
  different nodes can hold the same `10.0.100.x` address and cannot reach each
  other at those IPs across nodes. Cross-node instance traffic must use an
  **OVN network** (cluster-wide, routed over geneve). DHCP leases are per-node
  (each member's dnsmasq runs the same ranges independently — harmless on
  isolated bridges) and OVN external-IP allocation is cluster-wide (no
  collisions between members).
- **Containers get no DHCP address?** Check the run-directory symlink (§5.4) —
  without it `ovn-controller` can't reach `br-int.mgmt` and won't claim logical
  ports.

### 12.2 Incus clustering

- **Preseed only re-applies on incus start.** After editing
  `virtualisation.incus.preseed`, run `systemctl restart incus-preseed.service`
  — a plain rebuild won't re-trigger it.
- **The preseed is idempotent.** On a cluster member it re-applies
  config/pools/networks/profiles and skips existing ones — storage pools and
  profiles are **cluster-scoped** (created once, shared), while managed bridge
  networks like `incusbr0` are **per-member**.
- **Minimum 3 members for HA.** Incus uses RAFT for its internal DB; with 3
  members it tolerates 1 failure. 2 members gives no quorum under failure.
- **Storage HA requires a replicated Ceph cluster.** Until node2/node3 are
  deployed the Ceph pool is size 1 — control-plane HA only. Deploy the other
  nodes (§4.2) for replicated storage.

### 12.3 DNS

- Instances on **bridge** networks are auto-registered by Incus itself as
  `<name>.incus` regardless of the private-project flag — private projects
  should use OVN networks only (see [§7.2](#72-per-project-dns)).
- Records update within the 60 s refresh tick — a query immediately after
  launch may NXDOMAIN for a moment.
- If **no instance can resolve anything**, check the `incusbr0` firewall rule
  (53/67/547 — §5.2); it's the classic first-boot failure on a new host.

### 12.4 Firewall

- **Do not** switch the backend to iptables — Incus refuses to start.
- If `nftables` was enabled but rules look missing, `sudo nft list ruleset` to
  inspect; the Incus-generated chains are added by incusd at runtime.

### 12.5 Ceph

- `ceph -s` should show `HEALTH_OK`. HEALTH_WARN `PG_DEGRADED` during the
  2-node transition is expected until the third OSD lands.
- If `MON_DOWN`/`OSD_DOWN`: `systemctl status ceph-mon-<id> ceph-osd-<id>`
  and the zvol: `zfs list zroot/ceph-osd0`.
- Bootstrap one-shots: phase1/phase2 are idempotent (sentinel files under
  `/var/lib/ceph/`, removed only if a phase failed midway —
  `systemctl restart ceph-bootstrap-phaseN.service` after fixing the cause).
  phase3 re-runs **every boot** to converge CRUSH + replication with the
  current topology — that's how growth needs no manual steps.
- **Grow 1 → 3 nodes:** deploy this repo on node2/node3 (same config, own
  `hostname` file). Their mons join (`a b c`), their OSDs register
  (`osd.1/2`), phase3 flips the `rbd` pool to `size 3 / min_size 2` and
  restores the host CRUSH rule. No pool rebuild, no data migration.
- **No redundancy until then.** The `rbd` pool is size 1 — a lost OSD is
  data loss.

---

## 13. Security Notes

- **Incus UI has no password auth.** Access is via TLS client certificates only
  (`sudo incus config trust add <device>`).
- **Firewall is nftables.** Do not enable `networking.firewall.backend =
  "iptables"` — Incus will refuse to start.
- **OVN ACLs** provide tenant network isolation natively (per logical network),
  keeping host nftables rules minimal.
- **ZFS encryption credentials** are requested at boot if datasets are
  encrypted (`boot.zfs.requestEncryptionCredentials = true`).
- **Secrets** are encrypted with age/sops; the private key at
  `/var/lib/sops/age.key` is the crown jewel — back it up (it is *not* in git).
- **Privileged admin user** `admin` is in `wheel` (sudo, password required) and
  `incus-admin`. Set its password with `sudo passwd admin` after install.
- **DNS privacy is non-discoverability, not isolation** — the real boundary is
  OVN segmentation + firewall (§7.2).

---

## 14. Roadmap & Known Gaps

Items tracked in `/root/desired.txt` that are not yet implemented:

- QinQ (double-tagged VLANs)
- Incus control-plane clustering (config prepared; join not yet performed —
  see [§9.2](#92-incus-control-plane-clustering))
- Distributed firewall via OVN ACLs (native, per-project)
- Automated single-file restore from remote ZFS snapshots
- ACME/Let's Encrypt for Incus UI (needs DNS-01 capable DNS server)

---

## 15. Quick Command Reference

### 15.1 Host & configuration

```bash
sudo nixos-rebuild switch          # apply config changes
cat /etc/nixos/hostname            # which host am I
nixos-generate-config --dir /etc/nixos/local   # regenerate hardware scan
```

### 15.2 Incus

```bash
incus list
incus launch images:debian/12 my-vm --vm
incus console <name>
incus project create tenant-a
incus network create tenant-a-net --type=ovn --project tenant-a
incus storage list
incus profile list
sudo incus config trust add my-workstation
```

### 15.3 Storage

```bash
zpool status
zfs list -t snapshot
sudo ceph -s
sudo ceph osd pool ls
sudo rbd ls --pool rbd
sudo rbd create my-disk --size 10G --pool rbd
sudo rbd info my-disk --pool rbd
sudo rbd map my-disk --pool rbd
```

### 15.4 Network / OVN

```bash
systemctl is-active incus nftables systemd-networkd ovn-northd
sudo systemctl status ovn-northd ovn-controller
sudo ovn-sbctl show
sudo ovn-nbctl show
sudo ovs-vsctl show
sudo nft list ruleset
```

### 15.5 Backup

```bash
sudo systemctl start rbd-backup.service     # manual backup run
sudo journalctl -u rbd-backup.service -f
sudo systemctl list-timers | grep -E 'rbd|zfs|incus-dns'
```

### 15.6 Service inventory

| Unit | Purpose |
|------|---------|
| `incus.service` | Incus daemon |
| `incus-preseed.service` | Re-applies preseed on every incus start |
| `incus-dns-refresh.service` / `.timer` | Per-project DNS records (60 s) |
| `ovsdb.service` / `ovs-vswitchd` | Open vSwitch base (via `virtualisation.vswitch`) |
| `ovn-nb-db` / `ovn-sb-db` | OVN DBs (central nodes) |
| `ovn-northd` / `ovn-controller` | OVN central controller / local chassis agent |
| `ceph-zfs-prep` | Creates `zroot/ceph-osd0` zvol if missing |
| `ceph-bootstrap-phase1/2`, `ceph-bootstrap-pool` | Ceph bootstrap/join (phase1/2, sentinel-gated) + topology tuning (phase3, every boot) |
| `ceph-mon-<id>` / `ceph-mgr-<id>` / `ceph-osd-<id>` | Ceph daemons (a/0 on z3-nix01, b/1 on node2, c/2 on node3) |
| `rbd-backup.service` / `.timer` | Nightly RBD → S3 backups (02:00) |
| `zfs-snapshot-{frequent,hourly,daily,weekly,monthly}.timer` | ZFS auto-snapshots |
| `systemd-networkd` | Host network backend |
| `sshd` | SSH |
| `sops-nix.service` | Decrypts secrets to `/run/secrets/` |

---

## 16. License

This configuration is specific to this NixOS installation. Adapt as needed for
your own hosts.
