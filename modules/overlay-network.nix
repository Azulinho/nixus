{ config, lib, pkgs, ... }:

let
  cfg = config.networking.overlayNetwork;
in
{
  options.networking.overlayNetwork = {
    enable = lib.mkEnableOption "multi-host L2 overlay network for VMs/LXC (FRR+EVPN only)";

    vni = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "VXLAN Network Identifier (VNI) for the overlay";
    };

    localAddress = lib.mkOption {
      type = lib.types.str;
      example = "172.16.3.4";
      description = "IP address of this host used as the VXLAN local VTEP endpoint and BGP router-id";
    };

    frrPeers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "172.16.3.5" "172.16.3.6" ];
      description = ''
        BGP neighbor addresses for the EVPN underlay.
        May be empty for a standalone host; add peers when you expand the cluster.
        In a large cluster, set this to your Route Reflector addresses only
        and let the RRs carry the full mesh.
      '';
    };

    frrAsn = lib.mkOption {
      type = lib.types.int;
      default = 64512;
      description = "BGP AS number for the EVPN fabric";
    };

    frrRouteReflectorClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "172.16.3.10" "172.16.3.11" ];
      description = ''
        BGP neighbors that are route-reflector clients of this host.
        Only set this on the 2–3 hosts acting as Route Reflectors.
        Regular nodes should leave this empty.
      '';
    };

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "br-evpn";
      description = "Name of the overlay bridge that VMs/LXC attach to";
    };

    overlaySubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.200.0.0/16";
      description = ''
        IP subnet that lives on the overlay (used by distributed firewall rules).
        Leave null if you run multiple subnets on the same VNI and prefer
        manual firewall rules.
      '';
    };

    firewall = {
      enable = lib.mkEnableOption "nftables firewall rules applied to the overlay";

      allowIncus = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow Incus API/UI ports from the overlay";
      };

      allowSsh = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow SSH from the overlay";
      };

      customRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = ''
          Extra nftables rules for the overlay.
          These are identical on every hypervisor — this is your distributed firewall.
          Example: allow TCP 443 from the overlay to any host.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ─────────────────────────────────────────────────────────────
    # 1. Kernel modules for overlay
    # ─────────────────────────────────────────────────────────────
    boot.kernelModules = [ "vxlan" "bridge" "8021q" ];
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 0;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 0;
      "net.bridge.bridge-nf-call-arptables" = lib.mkDefault 0;
    };

    # ─────────────────────────────────────────────────────────────
    # 2. VXLAN netdev (learning enabled; FRR populates FDB)
    # ─────────────────────────────────────────────────────────────
    systemd.network.netdevs."30-vxlan-overlay" = {
      netdevConfig = {
        Name = "vxlan${toString cfg.vni}";
        Kind = "vxlan";
      };
      extraConfig = ''
        [VXLAN]
        VNI=${toString cfg.vni}
        Local=${cfg.localAddress}
        DestinationPort=4789
        Independent=yes
        Learning=yes
      '';
    };

    # ─────────────────────────────────────────────────────────────
    # 3. Overlay bridge via systemd-networkd
    # ─────────────────────────────────────────────────────────────
    systemd.network.netdevs."30-br-overlay" = {
      netdevConfig = {
        Name = cfg.bridgeName;
        Kind = "bridge";
      };
    };

    systemd.network.networks."30-br-overlay" = {
      matchConfig.Name = cfg.bridgeName;
      networkConfig = {
        DHCP = "no";
        LinkLocalAddressing = "no";
      };
    };

    # Attach VXLAN interface to the bridge automatically on boot
    systemd.services.overlay-bridge-setup = {
      description = "Attach VXLAN tunnel to overlay bridge";
      after = [ "systemd-networkd.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "overlay-bridge-setup" ''
          ${pkgs.iproute2}/bin/ip link set vxlan${toString cfg.vni} master ${cfg.bridgeName} || true
          ${pkgs.iproute2}/bin/ip link set vxlan${toString cfg.vni} up || true
        '';
      };
    };

    # ─────────────────────────────────────────────────────────────
    # 4. FRR + BGP/EVPN (always enabled when overlay is on)
    # ─────────────────────────────────────────────────────────────
    services.frr = {
      zebra = {
        enable = true;
        config = ''
          ip forwarding
          ipv6 forwarding
        '';
      };
      bgp = {
        enable = true;
        config = let
          allNeighbors = lib.unique (cfg.frrPeers ++ cfg.frrRouteReflectorClients);
          neighborStanza = lib.concatMapStringsSep "\n  " (peer:
            "neighbor ${peer} remote-as ${toString cfg.frrAsn}"
          ) allNeighbors;
          rrClientStanza = lib.concatMapStringsSep "\n  " (client:
            "neighbor ${client} route-reflector-client"
          ) cfg.frrRouteReflectorClients;
        in ''
          router bgp ${toString cfg.frrAsn}
           bgp router-id ${cfg.localAddress}
           no bgp default ipv4-unicast
           ${neighborStanza}
           ${rrClientStanza}
           address-family l2vpn evpn
            ${lib.concatMapStringsSep "\n    " (peer: "neighbor ${peer} activate") allNeighbors}
            advertise-all-vni
           exit-address-family
        '';
      };
    };

    # ─────────────────────────────────────────────────────────────
    # 5. nftables firewall rules for the overlay (distributed)
    # ─────────────────────────────────────────────────────────────
    networking.nftables.tables.overlay = lib.mkIf cfg.firewall.enable {
      family = "inet";
      content = let
        subnetMatch = lib.optionalString (cfg.overlaySubnet != null)
          ''ip saddr ${cfg.overlaySubnet}'';
      in ''
        chain overlay-input {
          type filter hook input priority 0; policy accept;

          # Allow traffic from overlay peers to local services
          ${lib.optionalString cfg.firewall.allowSsh ''
            ${lib.optionalString (cfg.overlaySubnet != null) ''ip saddr ${cfg.overlaySubnet}''} tcp dport 22 accept
          ''}

          ${lib.optionalString cfg.firewall.allowIncus ''
            ${lib.optionalString (cfg.overlaySubnet != null) ''ip saddr ${cfg.overlaySubnet}''} tcp dport 8443 accept
          ''}

          ${cfg.firewall.customRules}
        }

        chain overlay-forward {
          type filter hook forward priority 0; policy accept;

          # Inter-VM/container traffic across the overlay
          # Uncomment the line below to enforce default-deny between
          # overlay hosts and only allow explicit rules.
          # ${subnetMatch} ${lib.optionalString (cfg.overlaySubnet != null) "oifname \"${cfg.bridgeName}\""} drop
        }
      '';
    };

    environment.systemPackages = with pkgs; [
      iproute2
      bridge-utils
      frr
    ];
  };
}
