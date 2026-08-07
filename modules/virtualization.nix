{ config, lib, pkgs, settings, ... }:

{
  # ============================================================================
  # Incus (KVM + LXC virtualization + Web UI)
  # ============================================================================
  virtualisation.incus = {
    enable = true;
    ui.enable = true;

    # Preseed configures server, storage, networking and the default profile
    preseed = {
      config = {
        "core.https_address" = ":8443";
        # Cluster traffic: bind to the node's stable underlay IP so members
        # can reach each other. Per-host values come from local/settings.nix
        # (localAddress, nodeIndex). A wildcard (:8443) is rejected by Incus
        # for cluster traffic — a concrete address is required. Cluster
        # membership itself is joined imperatively (join tokens are
        # single-use) — see README.
        "cluster.https_address" = "${settings.localAddress}:8443";
        # OVN SDN integration (project-scoped networks). incusd accepts a
        # single NB remote; we point it at centralNodes[0] (node1) on every
        # host. OVSDB RAFT redirect covers leader changes while node1 is
        # reachable — see README.
        "network.ovn.northbound_connection" = "tcp:${lib.elemAt settings.centralNodes 0}:6641";
        "network.ovn.integration_bridge" = "br-int";
      };

      # Storage: Ceph RBD only (ZFS pool removed)
      storage_pools = [
        {
          name = "ceph";
          driver = "ceph";
          config = {
            source = "rbd";
            "ceph.user.name" = "admin";
            "ceph.cluster_name" = "ceph";
          };
        }
      ];

      # Networks: managed bridge with NAT (SDN foundation)
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.0.100.1/24";
            "ipv4.nat" = "true";
            "ipv6.address" = "fd42:100::1/64";
            "ipv6.nat" = "true";
            # Serve per-project instance records (written by the
            # incus-dns-refresh timer) through the fabric dnsmasq.
            "raw.dnsmasq" = "addn-hosts=/run/incus-dns/hosts.d";
          };
        }
      ];

      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "ceph";
              type = "disk";
            };
          };
        }
        {
          name = "ceph";
          devices = {
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "ceph";
              type = "disk";
            };
          };
        }
        {
          name = "router";
          description = "Lightweight VM profile for tenant virtual routers (OpenWrt/VyOS/OPNsense)";
          config = {
            "limits.cpu" = "2";
            "limits.memory" = "256MiB";
            "security.secureboot" = "false";
          };
          devices = {
            root = {
              path = "/";
              pool = "ceph";
              type = "disk";
              size = "2GiB";
            };
          };
        }
      ];
    };
  };

  # ZFS dataset prep removed — storage is now Ceph RBD only

  # Kernel tweaks for virtualization host
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Kernel Same-page Merging — deduplicate identical memory pages across VMs
  hardware.ksm.enable = true;

  environment.systemPackages = with pkgs; [
    incus
    qemu_kvm
    # Tools for SPICE/HTML5 console (used by Incus VMs via UI)
    virt-viewer
  ];
}
