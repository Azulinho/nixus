{ config, lib, pkgs, settings, ... }:

let
  cfg = config.services.ceph;

  # ─────────────────────────────────────────────────────────────
  # Cluster-wide identity — SAME on every host. This module is
  # "one Ceph cluster" whose nodes are exactly the hosts listed in
  # settings.cephNodes. Growth = deploy this same config to more
  # hosts; hosts that are configured but not yet deployed are
  # simply unreachable, which is harmless while the deployed mons
  # keep quorum.
  # ─────────────────────────────────────────────────────────────
  fsid = settings.cephFsid;
  monIps = settings.cephNodes;                 # one mon IP per node
  monHost = lib.concatStringsSep "," monIps;
  monNames = lib.imap0 (i: _: monName i) monIps;   # [ "a" "b" "c" ]
  monInitialMembers = lib.concatStringsSep " " monNames;

  # Per-host daemon ids (nodeIndex 0 → mon a, mgr a, osd 0).
  idx = settings.nodeIndex;
  monId = monName idx;
  mgrId = monId;
  osdId = toString idx;
  monIp = settings.localAddress;
  # Only the first node may bootstrap a brand-new cluster; every other
  # node joins the existing one.
  isPrimary = idx == 0;

  # monName n = "a" + n … (supports up to 26 mons)
  monName = n: builtins.substring n 1 "abcdefghijklmnopqrstuvwxyz";

  # SHARED cluster keyrings, distributed via sops so every node uses the
  # same auth (one cluster, not one cluster per host). Generate/encrypt
  # once on the first node:
  #   sudo scripts/ceph-init-keys.sh
  adminKeyring = config.sops.secrets.cephClientAdminKeyring.path;
  monKeyring   = config.sops.secrets.cephMonKeyring.path;

  cephBin = "${pkgs.ceph.out}/bin";

  # ─────────────────────────────────────────────────────────────
  # Phase 1: bring THIS host's mon up.
  #  - primary node's first ever boot → bootstrap a new cluster
  #  - any other node → join the existing cluster (fetch live monmap,
  #    add ourselves, mkfs with the shared mon keyring)
  #  - subsequent boots → idempotent (done marker)
  # Runs before ceph-mon-<id>.service, which has a ConditionPathExists
  # on the mon keyring we install here.
  # ─────────────────────────────────────────────────────────────
  phase1 = pkgs.writeShellScript "ceph-bootstrap-phase1" ''
    set -euo pipefail
    ID=${monId}
    SENTINEL=/var/lib/ceph/.phase1-done
    DATA_DIR=/var/lib/ceph/mon/ceph-$ID

    # Idempotency: already bootstrapped this mon, or sentinel survived reboot.
    if [ -f "$SENTINEL" ] || [ -f "$DATA_DIR/done" ]; then
      touch "$SENTINEL"
      exit 0
    fi

    mkdir -p /etc/ceph "$DATA_DIR"
    chown -R ceph:ceph "$DATA_DIR"

    # Install the SHARED cluster keyrings (from sops). Every node gets the
    # same admin keyring (used by incusd, rbd-backup, the CLI) and the same
    # mon keyring (so a joining mon can authenticate with the existing mons).
    install -o ceph -g ceph -m 0640 ${adminKeyring} /etc/ceph/ceph.client.admin.keyring
    install -o ceph -g ceph -m 0640 ${monKeyring}   /tmp/ceph.mon.keyring
    install -o ceph -g ceph -m 0640 ${monKeyring}   "$DATA_DIR/keyring"

    MONMAP="$DATA_DIR/monmap"
    if [ ! -f "$MONMAP" ]; then
      if ${cephBin}/ceph -s --connect-timeout 5 >/dev/null 2>&1; then
        # An existing cluster is reachable → JOIN it.
        echo "Joining existing Ceph cluster as mon $ID"
        ${cephBin}/ceph mon getmap -o /tmp/monmap
        ${cephBin}/ceph mon add "$ID" ${monIp} || true   # idempotent
        ${cephBin}/ceph mon getmap -o /tmp/monmap        # re-fetch (now includes us)
      elif [ ${if isPrimary then "true" else "false"} = true ]; then
        # First node of a brand-new cluster → bootstrap it.
        echo "Bootstrapping new Ceph cluster as mon $ID"
        ${cephBin}/monmaptool --create --add "$ID" ${monIp} \
          --fsid ${fsid} /tmp/monmap
      else
        echo "No reachable Ceph cluster and this is not the primary mon; will retry." >&2
        exit 1
      fi
      chown ceph:ceph /tmp/monmap
      ${pkgs.util-linux}/bin/runuser -u ceph -- \
        ${cephBin}/ceph-mon --mkfs -i "$ID" --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring
    fi

    touch "$DATA_DIR/done"
    touch "$SENTINEL"
  '';

  # ─────────────────────────────────────────────────────────────
  # Phase 2: bring THIS host's mgr + osd up (unique ids per node).
  # ─────────────────────────────────────────────────────────────
  phase2 = pkgs.writeShellScript "ceph-bootstrap-phase2" ''
    set -euo pipefail
    SENTINEL=/var/lib/ceph/.phase2-done
    [ -f "$SENTINEL" ] && exit 0

    MGR_ID=${mgrId}
    OSD_ID=${osdId}
    OSD_DIR=/var/lib/ceph/osd/ceph-$OSD_ID

    # Wait for a reachable mon (this host's own, or the cluster's).
    for i in $(seq 1 90); do
      ${cephBin}/ceph -s --connect-timeout 5 >/dev/null 2>&1 && break
      sleep 2
    done

    # Cluster-wide one-time tunings (idempotent, safe on every node).
    ${cephBin}/ceph mon enable-msgr2 || true
    ${cephBin}/ceph config set mon auth_allow_insecure_global_id_reclaim false || true

    # mgr keyring for THIS node's mgr daemon.
    mkdir -p /var/lib/ceph/mgr/ceph-$MGR_ID
    ${cephBin}/ceph auth get-or-create mgr.$MGR_ID \
      mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
      > /var/lib/ceph/mgr/ceph-$MGR_ID/keyring
    chown -R ceph:ceph /var/lib/ceph/mgr/ceph-$MGR_ID

    # OSD: unique id per node (osd.<nodeIndex>), registered with the cluster.
    mkdir -p "$OSD_DIR"
    if [ -f "$OSD_DIR/fsid" ]; then
      OSD_UUID=$(cat "$OSD_DIR/fsid")
    else
      OSD_UUID=$(${pkgs.util-linux}/bin/uuidgen)
    fi

    if ! ${cephBin}/ceph osd dump -f json | ${pkgs.jq}/bin/jq -e \
         --argjson id "$OSD_ID" '.osds[] | select(.id == $id)' >/dev/null 2>&1; then
      OSD_KEY=$(${cephBin}/ceph-authtool --gen-print-key)
      ${cephBin}/ceph-authtool --create-keyring "$OSD_DIR/keyring" \
        --name osd.$OSD_ID --add-key "$OSD_KEY"
      echo "{\"cephx_secret\": \"$OSD_KEY\"}" | \
        ${cephBin}/ceph osd new "$OSD_UUID" "$OSD_ID" -i -
    fi

    # Link the zvol and init bluestore (once).
    echo bluestore > "$OSD_DIR/type"
    ln -sf /dev/zvol/zroot/ceph-osd0 "$OSD_DIR/block"
    if [ ! -f "$OSD_DIR/fsid" ]; then
      ${cephBin}/ceph-osd -i "$OSD_ID" --mkfs --osd-uuid "$OSD_UUID"
    fi
    chown -R ceph:disk "$OSD_DIR"

    # Explicitly start mgr and osd — systemd may have already evaluated their
    # ConditionPathExists and skipped them in this transaction.
    systemctl start ceph-mgr-$MGR_ID.service ceph-osd-$OSD_ID.service

    touch "$SENTINEL"
  '';

  # ─────────────────────────────────────────────────────────────
  # Phase 3: tune CRUSH + pool replication for the CURRENT topology.
  # No sentinel — re-evaluated on every boot of every node, so it
  # converges automatically when more OSD hosts join the cluster:
  #   1 host with OSDs  → single-node (no replication, osd failure domain)
  #   ≥2 hosts with OSDs → replicated cluster (host failure domain, size 3)
  # ─────────────────────────────────────────────────────────────
  phase3 = pkgs.writeShellScript "ceph-bootstrap-pool" ''
    set -euo pipefail

    # Wait for a reachable (and ideally healthy) cluster.
    for i in $(seq 1 120); do
      ${cephBin}/ceph -s 2>/dev/null | grep -q HEALTH && break
      sleep 2
    done

    OSD_HOSTS=$(${cephBin}/ceph osd tree -f json | ${pkgs.jq}/bin/jq \
      '[.nodes[] | select(.type == "host" and ((.children // []) | length > 0))] | length')
    if [ "$OSD_HOSTS" -ge 2 ]; then MODE=multi; else MODE=single; fi
    echo "Ceph topology: $OSD_HOSTS OSD host(s) → $MODE-node mode"

    # ── CRUSH rule ──
    # A single node must choose leaf OSDs directly (all OSDs share one
    # host); a real cluster uses the host failure domain for replication.
    ${cephBin}/ceph osd getcrushmap -o /tmp/crush
    ${cephBin}/crushtool -d /tmp/crush -o /tmp/decrushed
    CHANGED=0
    if [ "$MODE" = multi ] && grep -q 'step chooseleaf firstn 0 type osd' /tmp/decrushed; then
      sed -i 's/step chooseleaf firstn 0 type osd/step chooseleaf firstn 0 type host/' /tmp/decrushed
      CHANGED=1
    fi
    if [ "$MODE" = single ] && grep -q 'step chooseleaf firstn 0 type host' /tmp/decrushed; then
      sed -i 's/step chooseleaf firstn 0 type host/step chooseleaf firstn 0 type osd/' /tmp/decrushed
      CHANGED=1
    fi
    if [ "$CHANGED" = 1 ]; then
      ${cephBin}/crushtool -c /tmp/decrushed -o /tmp/recrushed
      ${cephBin}/ceph osd setcrushmap -i /tmp/recrushed
    fi

    # ── rbd pool (created once, then sized per mode) ──
    if ! ${cephBin}/ceph osd pool ls | grep -qx rbd; then
      if [ "$OSD_HOSTS" -ge 3 ]; then
        ${cephBin}/ceph osd pool create rbd 32 32 --size 3
      else
        ${cephBin}/ceph osd pool create rbd 32 32
      fi
      ${cephBin}/ceph osd pool application enable rbd rbd
    fi

    if [ "$MODE" = multi ]; then
      ${cephBin}/ceph osd pool set rbd size 3 || true
      ${cephBin}/ceph osd pool set rbd min_size 2 || true
      ${cephBin}/ceph osd pool set .mgr size 3 || true
      ${cephBin}/ceph config set global osd_pool_default_size 3 || true
      ${cephBin}/ceph config set global osd_pool_default_min_size 2 || true
      ${cephBin}/ceph config set global mon_warn_on_pool_no_redundancy true || true
    else
      ${cephBin}/ceph osd pool set rbd size 1 || true
      ${cephBin}/ceph osd pool set rbd min_size 1 || true
      ${cephBin}/ceph config set global osd_pool_default_size 1 || true
      ${cephBin}/ceph config set global osd_pool_default_min_size 1 || true
      ${cephBin}/ceph config set global mon_warn_on_pool_no_redundancy false || true
    fi

    touch /var/lib/ceph/.phase3-done
  '';
in
{
  # ─────────────────────────────────────────────────────────────
  # ZFS zvol for this node's OSD backing store (per-host zroot).
  # ─────────────────────────────────────────────────────────────
  systemd.services.ceph-zfs-prep = {
    description = "Prepare ZFS zvol for Ceph OSD";
    before = [ "ceph-bootstrap-phase1.service" ];
    wantedBy = [ "ceph-bootstrap-phase1.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "ceph-zfs-prep" ''
        ${pkgs.zfs}/bin/zfs list zroot/ceph-osd0 >/dev/null 2>&1 || \
          ${pkgs.zfs}/bin/zfs create -V 20G -o compression=off \
            -o primarycache=none -o secondarycache=none zroot/ceph-osd0
      '';
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Ceph daemon configuration — only THIS host's daemons.
  # The mon list (monHost/monInitialMembers) is the full cluster on
  # every host, so clients can find mons wherever they live.
  # ─────────────────────────────────────────────────────────────
  services.ceph = {
    enable = true;
    global = {
      fsid = fsid;
      monHost = monHost;
      monInitialMembers = monInitialMembers;
    };
    extraConfig = {
      # Start-of-life defaults; phase3 flips these cluster-wide (config
      # store) once the cluster grows past one OSD host.
      "osd pool default size" = "1";
      "osd pool default min size" = "1";
      "mon warn on pool no redundancy" = "false";
    };
    mon = {
      enable = true;
      daemons = [ monId ];
    };
    mgr = {
      enable = true;
      daemons = [ mgrId ];
    };
    osd = {
      enable = true;
      daemons = [ osdId ];
    };
    client = {
      enable = true;
    };
  };

  # Ceph public-network ports (msgr2: 3300, msgr1: 6789) — needed between
  # cluster nodes once there is more than one.
  networking.firewall.allowedTCPPorts = [ 3300 6789 ];

  # ─────────────────────────────────────────────────────────────
  # Bootstrap services
  # ─────────────────────────────────────────────────────────────
  systemd.services.ceph-bootstrap-phase1 = {
    description = "Bootstrap or join Ceph mon";
    before = [ "ceph-mon-${monId}.service" ];
    after = [ "network-online.target" "time-sync.target" "sops-nix.service" ];  # shared keyrings come from /run/secrets
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph-mon.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";   # joining nodes retry until the cluster is reachable
      RestartSec = "15";
      ExecStart = phase1;
    };
  };

  systemd.services.ceph-bootstrap-phase2 = {
    description = "Bootstrap Ceph mgr and osd";
    before = [ "ceph-mgr-${mgrId}.service" "ceph-osd-${osdId}.service" ];
    after = [ "ceph-mon-${monId}.service" "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15";
      ExecStart = phase2;
    };
  };

  systemd.services.ceph-bootstrap-pool = {
    description = "Tune Ceph CRUSH and pool replication for current topology";
    before = [ "ceph.target" ];
    after = [ "ceph-osd-${osdId}.service" "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15";
      ExecStart = phase3;
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Tools
  # ─────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [ ceph jq ];
}
