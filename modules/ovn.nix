{ config, lib, pkgs, ... }:

let
  cfg = config.networking.ovn;
  ovnPkg = pkgs.ovn;
  ovsPkg = pkgs.openvswitch;
  runDir = "/run/ovn";
  dataDir = "/var/lib/ovn";
  isCentral = cfg.role == "central";
  isClustered = isCentral && (builtins.length cfg.centralNodes) > 1;

  # Connection strings used by ovn-northd and ovn-controller.
  # Point at all central nodes so controllers survive one central failure.
  nbRemotes = lib.concatMapStringsSep "," (ip: "tcp:${ip}:6641") cfg.centralNodes;
  sbRemotes = lib.concatMapStringsSep "," (ip: "tcp:${ip}:6642") cfg.centralNodes;

  # Other central nodes (excluding this host) — for RAFT join.
  peerAddrs = lib.filter (x: x != null) (
    lib.imap0 (i: ip: if i == cfg.nodeIndex then null else ip) cfg.centralNodes
  );
  firstPeer = lib.optionalString (peerAddrs != []) (builtins.elemAt peerAddrs 0);

  # Pre-start script that bootstraps the DB file:
  #   standalone: ovsdb-tool create
  #   clustered node 0: ovsdb-tool create-cluster (forms RAFT cluster)
  #   clustered join:  ovsdb-tool join-cluster
  dbBootstrap = name: schemaName: clusterPort: schema: pkgs.writeShellScript "ovn-${name}-bootstrap" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir -p ${runDir} ${dataDir}
    ${pkgs.coreutils}/bin/chmod 755 ${runDir}
    DB=${dataDir}/${name}.db
    if [ ! -f "$DB" ]; then
      if [ "${toString isClustered}" = "1" ]; then
        if [ "${toString cfg.nodeIndex}" = "0" ]; then
          ${ovsPkg}/bin/ovsdb-tool create-cluster "$DB" ${schema} \
            tcp:${cfg.localAddress}:${toString clusterPort} >/dev/null
        else
          ${ovsPkg}/bin/ovsdb-tool join-cluster "$DB" ${schemaName} \
            tcp:${cfg.localAddress}:${toString clusterPort} \
            tcp:${firstPeer}:${toString clusterPort} >/dev/null
        fi
      else
        ${ovsPkg}/bin/ovsdb-tool create "$DB" ${schema}
      fi
    fi
  '';

  # ovsdb-server invocation: unix socket (local tools) + tcp (cluster/remotes).
  # NB clients use port 6641, SB clients 6642. RAFT cluster ports 6643/6644.
  dbServer = name: clientPort: ''
    ${ovsPkg}/bin/ovsdb-server \
      --remote=punix:${runDir}/${name}_db.sock \
      --remote=ptcp:${toString clientPort}:${cfg.localAddress} \
      --pidfile=${runDir}/${name}_db.pid \
      --log-file=/var/log/ovn/${name}-db.log \
      ${dataDir}/${name}.db
  '';
in
{
  options.networking.ovn = {
    enable = lib.mkEnableOption "OVN SDN controller (multi-host)";

    role = lib.mkOption {
      type = lib.types.enum [ "central" "compute" ];
      default = "central";
      description = ''
        central: run the OVN NB/SB databases and ovn-northd.
                 Use on the first 3 hosts for a RAFT-quorum control plane.
        compute: run only OVS + ovn-controller. Use on all other hosts.
      '';
    };

    centralNodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "172.16.3.1" "172.16.3.2" "172.16.3.3" ];
      description = ''
        Underlay IPs of the OVN central nodes. Set the same list on every host.
        With 1 entry: standalone DBs (single control node, no HA).
        With 3+ entries: RAFT-clustered DBs for HA.
      '';
    };

    nodeIndex = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "This host's index within centralNodes (0..N). Only used when role = central.";
    };

    localAddress = lib.mkOption {
      type = lib.types.str;
      description = "This host's underlay IP, used for OVN geneve encapsulation.";
    };

    clusterPort = lib.mkOption {
      type = lib.types.int;
      default = 6643;
      description = "Base RAFT cluster port for the NB DB. SB uses +1 (6644).";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─────────────────────────────────────────────────────────────
    # OVS base (ovsdb-server + ovs-vswitchd) — required everywhere
    # ─────────────────────────────────────────────────────────────
    virtualisation.vswitch.enable = true;

    environment.systemPackages = [ ovnPkg ovsPkg ];

    # OVN is compiled with /usr/local prefix but NixOS OVS uses /run/openvswitch.
    # Symlink the run dir so ovn-controller can find br-int.mgmt/br-int.snoop.
    systemd.tmpfiles.rules = [
      "L+ /usr/local/var/run/openvswitch - - - - /run/openvswitch"
    ];

    # incus-preseed validates network.ovn.northbound_connection by connecting,
    # so on central nodes it must wait for the NB database.
    systemd.services.incus-preseed.after = lib.mkIf isCentral [ "ovn-nb-db.service" ];

    # ─────────────────────────────────────────────────────────────
    # OVN northbound database (central nodes only)
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-nb-db = lib.mkIf isCentral {
      description = "OVN Northbound Database Server";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = dbBootstrap "ovnnb" "OVN_Northbound" cfg.clusterPort "${ovnPkg}/share/ovn/ovn-nb.ovsschema";
        ExecStart = dbServer "ovnnb" 6641;
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # OVN southbound database (central nodes only)
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-sb-db = lib.mkIf isCentral {
      description = "OVN Southbound Database Server";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = dbBootstrap "ovnsb" "OVN_Southbound" (cfg.clusterPort + 1) "${ovnPkg}/share/ovn/ovn-sb.ovsschema";
        ExecStart = dbServer "ovnsb" 6642;
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # ovn-northd — central controller (central nodes only)
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-northd = lib.mkIf isCentral {
      description = "OVN Northd Daemon";
      after = [ "ovn-nb-db.service" "ovn-sb-db.service" ];
      requires = [ "ovn-nb-db.service" "ovn-sb-db.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${ovnPkg}/bin/ovn-northd \
            --ovnnb-db=${nbRemotes} \
            --ovnsb-db=${sbRemotes}
        '';
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # ovn-controller — local agent on EVERY hypervisor
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-controller = {
      description = "OVN Controller";
      after = [ "ovsdb.service" ] ++ (lib.optionals isCentral [ "ovn-sb-db.service" ]);
      requires = [ "ovsdb.service" ] ++ (lib.optionals isCentral [ "ovn-sb-db.service" ]);
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "ovn-controller-prestart" ''
          SYSTEM_ID=$(cat /etc/machine-id)
          ${ovsPkg}/bin/ovs-vsctl set open_vswitch . \
            external_ids:system-id=$SYSTEM_ID \
            external_ids:ovn-remote=${sbRemotes} \
            external_ids:ovn-encap-type=geneve \
            external_ids:ovn-encap-ip=${cfg.localAddress}
        '';
        ExecStart = ''
          ${ovnPkg}/bin/ovn-controller \
            unix:/run/openvswitch/db.sock
        '';
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
