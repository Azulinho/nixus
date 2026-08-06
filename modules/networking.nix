{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # Network stack: systemd-networkd, VLAN, Bond, Firewall, NAT/SNAT
  # ============================================================================

  # Switch from NetworkManager to systemd-networkd for server-grade networking
  networking.useNetworkd = true;
  networking.networkmanager.enable = lib.mkForce false;

  # Base uplink (detected as ens18 on this host)
  systemd.network.networks."10-ens18" = {
    matchConfig.Name = "ens18";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };

  # ============================================================================
  # VLAN & Bonding support (kernel modules + tools)
  # ============================================================================
  boot.kernelModules = [ "8021q" "bonding" ];
  networking.vlans = {
    # Example: VLAN 100 on ens18 (activate as needed)
    # "ens18.100" = { id = 100; interface = "ens18"; };
  };

  networking.bonds = {
    # Example: LACP bond (activate and add real interfaces as needed)
    # "bond0" = {
    #   interfaces = [ "ens18" "ens19" ];
    #   driverOptions = {
    #     mode = "802.3ad";
    #     miimon = "100";
    #     lacp_rate = "fast";
    #   };
    # };
  };

  # ============================================================================
  # Firewall: IPv4 + IPv6 support
  # ============================================================================
  # Incus requires nftables; enable both the nftables subsystem and firewall backend
  networking.nftables.enable = true;
  networking.firewall.backend = "nftables";

  networking.firewall = {
    enable = true;
    allowPing = true;

    # Allow SSH and Incus HTTPS / Web UI
    allowedTCPPorts = [
      22    # SSH
      8443  # Incus UI / API
    ];

    # Allow forwarding traffic for Incus bridges and Podman networks
    filterForward = false;
  };

  # ============================================================================
  # Host bridge for SDN / direct VM-to-host L2 (optional)
  # ============================================================================
  # If you want VMs on the same L2 as the host (instead of NAT via incusbr0),
  # uncomment the bridge below and move the IP config from ens18 to br0.
  #
  # systemd.network.netdevs."20-br0" = {
  #   netdevConfig = {
  #     Name = "br0";
  #     Kind = "bridge";
  #   };
  # };
  # systemd.network.networks."20-br0" = {
  #   matchConfig.Name = "br0";
  #   networkConfig = {
  #     DHCP = "yes";
  #     IPv6AcceptRA = true;
  #   };
  # };
  # systemd.network.networks."10-ens18" = {
  #   matchConfig.Name = "ens18";
  #   networkConfig.Bridge = "br0";
  # };
}
