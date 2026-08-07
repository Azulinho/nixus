{ config, lib, pkgs, ... }:

# ============================================================================
# Per-project DNS for Incus (OVN + bridge networks)
#
# Incus 7.0.1 hands every OVN network DHCP option 6 = the uplink gateway
# (10.0.100.1), i.e. the uplink dnsmasq is the resolver for the whole fabric.
# It does NOT, however, generate name→IP records for OVN instances
# (`dns.zone` is unsupported on OVN networks; `dns.mode` is inert).
#
# This module closes that gap:
#   - hooks an addn-hosts directory into the uplink dnsmasq
#     (raw.dnsmasq on incusbr0, set via the Incus preseed)
#   - periodically reads `incus list` per project and writes
#     /run/incus-dns/hosts.d/<project> with records of the form
#         <instance>.<project>.<zone>
#   - SIGHUPs dnsmasq to reload
#
# Combined with `incus network set <net> dns.search=<project>.<zone>` on each
# project's OVN network, instances resolve peers by short name too, e.g.
#     vm1  →  vm1.project1.incus-cluster1.mydomain → 10.230.79.2
# Cross-project resolution works automatically (single resolver holds all
# projects' zones).
# ============================================================================

let
  cfg = config.services.incusDns;

  refreshScript = pkgs.writeShellScript "incus-dns-refresh" ''
    set -u

    # writeShellScript does not inherit PATH; put the tools we need on it.
    export PATH=${lib.makeBinPath (with pkgs; [ incus jq procps coreutils findutils ])}

    ZONE=${lib.escapeShellArg cfg.zone}
    HOSTS_DIR=${lib.escapeShellArg cfg.hostsDir}

    # dnsmasq is spawned by incusd (not a systemd unit); if it is not up yet,
    # there is nothing to feed. The timer retries on the next tick.
    DNSMASQ_PID=$(pgrep -x dnsmasq | head -n1 || true)
    [ -n "$DNSMASQ_PID" ] || exit 0

    mkdir -p "$HOSTS_DIR"

    # Rewrite from scratch every refresh so stale records (moved/deleted
    # instances) disappear.
    find "$HOSTS_DIR" -mindepth 1 -maxdepth 1 -type f -delete

    INCUS=${lib.escapeShellArg "${pkgs.incus}/bin/incus"}

    # All projects ("default (current)" is normalised to "default").
    while read -r project; do
      [ -n "$project" ] || continue

      out="$HOSTS_DIR/$project"
      : > "$out"

      "$INCUS" list --project "$project" --format json 2>/dev/null \
        | jq -r --arg zone "$ZONE" --arg project "$project" '
            .[] as $i |
            select($i.status == "Running") |
            $i.name as $name |
            (($i.state.network // {}) | to_entries | first | .value.addresses) as $addrs |
            (($addrs | map(select(.family == "inet")) | first)
             // ($addrs | map(select(.family == "inet6" and .scope == "global")) | first)) as $ip |
            if $ip == null then empty
            else "\($ip.address)\t\($name).\($project).\($zone)\t\($name)"
            end' >> "$out"
    done < <("$INCUS" project list --format csv | cut -d, -f1 | cut -d' ' -f1)

    kill -HUP "$DNSMASQ_PID" 2>/dev/null || true
  '';
in
{
  options.services.incusDns = {
    enable = lib.mkEnableOption "per-project DNS for Incus via the uplink dnsmasq";

    zone = lib.mkOption {
      type = lib.types.str;
      example = "incus-cluster1.mydomain";
      description = ''
        Parent zone under which per-project names are served.
        Records take the form <instance>.<project>.<zone>.
      '';
    };

    hostsDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/incus-dns/hosts.d";
      description = ''
        Directory of addn-hosts files read by the uplink dnsmasq
        (one file per Incus project). Must match the raw.dnsmasq
        'addn-hosts=' path configured on incusbr0.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Seconds between refreshes of instance DNS records.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Directory exists before dnsmasq (started by incusd) reads it.
    systemd.tmpfiles.rules = [ "d ${cfg.hostsDir} 0755 root root -" ];

    systemd.services.incus-dns-refresh = {
      description = "Refresh Incus instance DNS records (per project)";
      after = [ "incus.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = refreshScript;
      };
    };

    systemd.timers.incus-dns-refresh = {
      description = "Periodically refresh Incus instance DNS records";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "${toString cfg.interval}";
        Unit = "incus-dns-refresh.service";
      };
    };
  };
}
