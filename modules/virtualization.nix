{ config, lib, pkgs, ... }:

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
      };

      # Storage: use ZFS dataset on the existing zroot pool
      storage_pools = [
        {
          name = "default";
          driver = "zfs";
          config = {
            source = "zroot/incus";
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
              pool = "default";
              type = "disk";
            };
          };
        }
      ];
    };
  };

  # Ensure the ZFS backing dataset exists before Incus initializes
  systemd.services.incus-zfs-prep = {
    description = "Prepare ZFS dataset for Incus storage";
    before = [ "incus.service" ];
    wantedBy = [ "incus.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "incus-zfs-prep" ''
        ${pkgs.zfs}/bin/zfs list zroot/incus >/dev/null 2>&1 || \
          ${pkgs.zfs}/bin/zfs create -o mountpoint=none zroot/incus
      '';
    };
  };

  # ============================================================================
  # Podman (OCI containers, Docker-compatible)
  # ============================================================================
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Kernel tweaks for virtualization host
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  environment.systemPackages = with pkgs; [
    incus
    podman
    podman-compose
    qemu_kvm
    # Tools for SPICE/HTML5 console (used by Incus VMs via UI)
    virt-viewer
  ];
}
