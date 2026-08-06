{ config, lib, pkgs, ... }:

let
  cfg = config.networking.overlayNetwork;
in
{
  options.networking.overlayNetwork = {
    enable = lib.mkEnableOption "multi-host L2 overlay network for VMs/LXC (FRR+EVPN only)";

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

    vnis = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          vni = lib.mkOption {
            type = lib.types.int;
            description = "VXLAN Network Identifier (VNI) for this segment";
          };
          bridgeName = lib.mkOption {
            type = lib.types.str;
            description = "Name of the Linux bridge that VMs/LXC attach to for this segment";
          };
          overlaySubnet = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "10.200.0.0/16";
            description = ''
              IP subnet that lives on this overlay segment (used by distributed firewall rules).
              Leave null if you run multiple subnets on the same VNI and prefer manual firewall rules.
            '';
          };
        };
      });
      default = [];
      example = lib.literalExpression ''
        [
          { vni = 10; bridgeName = "br-tenant-a"; overlaySubnet = "10.10.0.0/16"; }
          { vni = 20; bridgeName = "br-tenant-b"; overlaySubnet = "10.20.0.0/16"; }
        ]
      '';
      description = ''
        List of VXLAN segments to create. Each segment gets its own VNI,
        its own bridge, and is independently advertised via EVPN.
        This lets you run multiple isolated L2 domains across the same
        hypervisor cluster without consuming 802.1q tags.
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
    assertions = [
      {
        assertion = cfg.vnis != [];
        message = "networking.overlayNetwork.vnis must contain at least one segment when the overlay is enabled.";
      }
    ];

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
    # 2. VXLAN netdevs and bridge netdevs (one pair per segment)
    # ─────────────────────────────────────────────────────────────
    systemd.network.netdevs = lib.listToAttrs (lib.concatMap (segment: [
      {
        name = "30-vxlan-${toString segment.vni}";
        value = {
          netdevConfig = {
            Name = "vxlan${toString segment.vni}";
            Kind = "vxlan";
          };
          extraConfig = ''
            [VXLAN]
            VNI=${toString segment.vni}
            Local=${cfg.localAddress}
            DestinationPort=4789
            Independent=yes
            Learning=yes
          '';
        };
      }
      {
        name = "30-br-${segment.bridgeName}";
        value = {
          netdevConfig = {
            Name = segment.bridgeName;
            Kind = "bridge";
          };
        };
      }
    ]) cfg.vnis);

    # ─────────────────────────────────────────────────────────────
    # 3. Bridge network configs (one per segment)
    # ─────────────────────────────────────────────────────────────
    systemd.network.networks = lib.listToAttrs (map (segment: {
      name = "30-br-${segment.bridgeName}";
      value = {
        matchConfig.Name = segment.bridgeName;
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
        };
      };
    }) cfg.vnis);

    # ─────────────────────────────────────────────────────────────
    # 4. Attach each VXLAN to its bridge on boot
    # ─────────────────────────────────────────────────────────────
    systemd.services = lib.listToAttrs (map (segment: {
      name = "${segment.bridgeName}-setup";
      value = {
        description = "Attach VXLAN ${toString segment.vni} to bridge ${segment.bridgeName}";
        after = [ "systemd-networkd.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "${segment.bridgeName}-setup" ''
            ${pkgs.iproute2}/bin/ip link set vxlan${toString segment.vni} master ${segment.bridgeName} || true
            ${pkgs.iproute2}/bin/ip link set vxlan${toString segment.vni} up || true
          '';
        };
      };
    }) cfg.vnis);

    # ─────────────────────────────────────────────────────────────
    # 5. FRR + BGP/EVPN (advertise-all-vni discovers every VXLAN)
    # ─────────────────────────────────────────────────────────────
    services.frr = {
      config = let
        allNeighbors = lib.unique (cfg.frrPeers ++ cfg.frrRouteReflectorClients);
        neighborStanza = lib.concatMapStringsSep "\n  " (peer:
          "neighbor ${peer} remote-as ${toString cfg.frrAsn}"
        ) allNeighbors;
        rrClientStanza = lib.concatMapStringsSep "\n  " (client:
          "neighbor ${client} route-reflector-client"
        ) cfg.frrRouteReflectorClients;
      in ''
        ip forwarding
        ipv6 forwarding
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
      bgpd.enable = true;
    };

    # ─────────────────────────────────────────────────────────────
    # 6. nftables firewall rules for the overlay (distributed)
    # ─────────────────────────────────────────────────────────────
    networking.nftables.tables.overlay = lib.mkIf cfg.firewall.enable {
      family = "inet";
      content = ''
        chain overlay-input {
          type filter hook input priority 0; policy accept;

          # Allow traffic from overlay peers to local services
          ${lib.concatMapStringsSep "\n" (segment:
            lib.optionalString (cfg.firewall.allowSsh && segment.overlaySubnet != null)
              ''ip saddr ${segment.overlaySubnet} tcp dport 22 accept''
          ) cfg.vnis}

          ${lib.concatMapStringsSep "\n" (segment:
            lib.optionalString (cfg.firewall.allowIncus && segment.overlaySubnet != null)
              ''ip saddr ${segment.overlaySubnet} tcp dport 8443 accept''
          ) cfg.vnis}

          ${cfg.firewall.customRules}
        }

        chain overlay-forward {
          type filter hook forward priority 0; policy accept;

          # Inter-VM/container traffic across the overlay
          # Uncomment to enforce default-deny and add explicit per-segment rules.
          # Example: ip saddr 10.10.0.0/16 oifname "br-tenant-a" drop
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
