{ config, lib, pkgs, ... }:

let
  cfg = config.networking.ovn;
  ovnPkg = pkgs.ovn;
  ovsPkg = pkgs.openvswitch;
  runDir = "/run/ovn";
  dataDir = "/var/lib/ovn";
in
{
  options.networking.ovn = {
    enable = lib.mkEnableOption "OVN SDN controller (northd + controller)";

    integrationBridge = lib.mkOption {
      type = lib.types.str;
      default = "br-int";
      description = "Name of the OVS integration bridge that Incus/OVN uses";
    };

    encapIp = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Underlay IP used for OVN encapsulation (geneve). Defaults to localAddress from the overlay module.";
    };
  };

  config = lib.mkIf cfg.enable {
    # OVS base (ovsdb-server + ovs-vswitchd) — required by OVN and Incus
    virtualisation.vswitch.enable = true;

    environment.systemPackages = [ ovnPkg ovsPkg ];

    # OVN is compiled with /usr/local prefix but NixOS OVS uses /run/openvswitch.
    # Symlink the run dir so ovn-controller can find br-int.mgmt/br-int.snoop.
    systemd.tmpfiles.rules = [
      "L+ /usr/local/var/run/openvswitch - - - - /run/openvswitch"
    ];

    # ─────────────────────────────────────────────────────────────
    # OVN northbound database
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-nb-db = {
      description = "OVN Northbound Database Server";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "ovn-nb-db-prestart" ''
          ${pkgs.coreutils}/bin/mkdir -p ${runDir} ${dataDir}
          ${pkgs.coreutils}/bin/chmod 755 ${runDir}
          if [ ! -f ${dataDir}/ovnnb.db ]; then
            ${ovsPkg}/bin/ovsdb-tool create ${dataDir}/ovnnb.db \
              ${ovnPkg}/share/ovn/ovn-nb.ovsschema
          fi
        '';
        ExecStart = ''
          ${ovsPkg}/bin/ovsdb-server \
            --remote=punix:${runDir}/ovnnb_db.sock \
            --pidfile=${runDir}/ovn-nb.pid \
            --log-file=/var/log/ovn-nb.log \
            ${dataDir}/ovnnb.db
        '';
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # OVN southbound database
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-sb-db = {
      description = "OVN Southbound Database Server";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "ovn-sb-db-prestart" ''
          ${pkgs.coreutils}/bin/mkdir -p ${runDir} ${dataDir}
          ${pkgs.coreutils}/bin/chmod 755 ${runDir}
          if [ ! -f ${dataDir}/ovnsb.db ]; then
            ${ovsPkg}/bin/ovsdb-tool create ${dataDir}/ovnsb.db \
              ${ovnPkg}/share/ovn/ovn-sb.ovsschema
          fi
        '';
        ExecStart = ''
          ${ovsPkg}/bin/ovsdb-server \
            --remote=punix:${runDir}/ovnsb_db.sock \
            --pidfile=${runDir}/ovn-sb.pid \
            --log-file=/var/log/ovn-sb.log \
            ${dataDir}/ovnsb.db
        '';
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # ovn-northd — central controller (syncs NB → SB)
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-northd = {
      description = "OVN Northd Daemon";
      after = [ "ovn-nb-db.service" "ovn-sb-db.service" ];
      requires = [ "ovn-nb-db.service" "ovn-sb-db.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${ovnPkg}/bin/ovn-northd \
            --db-ovnnb=unix:${runDir}/ovnnb_db.sock \
            --db-ovnsb=unix:${runDir}/ovnsb_db.sock
        '';
        Restart = "always";
        RestartSec = 3;
      };
    };

    # ─────────────────────────────────────────────────────────────
    # ovn-controller — local agent (applies SB state to OVS)
    # ─────────────────────────────────────────────────────────────
    systemd.services.ovn-controller = {
      description = "OVN Controller";
      after = [ "ovsdb.service" "ovn-sb-db.service" ];
      requires = [ "ovsdb.service" "ovn-sb-db.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "ovn-controller-prestart" ''
          SYSTEM_ID=$(cat /etc/machine-id)
          ${ovsPkg}/bin/ovs-vsctl set open_vswitch . \
            external_ids:system-id=$SYSTEM_ID \
            external_ids:ovn-remote=unix:${runDir}/ovnsb_db.sock \
            external_ids:ovn-encap-type=geneve \
            external_ids:ovn-encap-ip=${cfg.encapIp}
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
