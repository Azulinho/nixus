{ config, lib, pkgs, settings, ... }:

let
  cfg = config.services.ceph;
  # Single-node Ceph on every host: the mon binds to THIS host's underlay IP.
  monIp = settings.localAddress;
  # Ceph cluster FSID — generated once, stored in local/settings.nix.
  fsid = settings.cephFsid;

  # ─────────────────────────────────────────────────────────────
  # Phase 1: create mon filesystem and keyrings (before ceph-mon)
  # ─────────────────────────────────────────────────────────────
  phase1 = pkgs.writeShellScript "ceph-bootstrap-phase1" ''
    set -euo pipefail
    SENTINEL=/var/lib/ceph/.phase1-done

    # Idempotency: skip if phase1 already ran (sentinel) OR the mon
    # filesystem is already initialized (done marker). Checking the mon
    # state directly guards against a lost sentinel after reboot: stale
    # ceph-owned keyrings left in persistent /tmp would otherwise make
    # ceph-authtool fail with EACCES (fs.protected_regular blocks root
    # from O_CREAT-overwriting other-owner files in sticky /tmp) and a
    # re-run would also clobber the existing admin keyring.
    if [ -f "$SENTINEL" ] || [ -f /var/lib/ceph/mon/ceph-a/done ]; then
      touch "$SENTINEL"
      exit 0
    fi

    mkdir -p /var/lib/ceph/mon/ceph-a
    mkdir -p /etc/ceph
    chown -R ceph:ceph /var/lib/ceph/mon/ceph-a

    # Remove stale keyrings/monmap from previous bootstrap attempts.
    # They may be owned by ceph:ceph, and with fs.protected_regular=1
    # root cannot O_CREAT-overwrite files owned by others inside /tmp.
    rm -f /tmp/ceph.mon.keyring /tmp/monmap

    # Generate mon keyring
    ${pkgs.ceph.out}/bin/ceph-authtool --create-keyring /tmp/ceph.mon.keyring \
      --gen-key -n mon. --cap mon 'allow *'

    # Generate admin keyring
    ${pkgs.ceph.out}/bin/ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring \
      --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' \
      --cap mds 'allow *' --cap mgr 'allow *'

    # Merge admin into mon keyring
    ${pkgs.ceph.out}/bin/ceph-authtool /tmp/ceph.mon.keyring \
      --import-keyring /etc/ceph/ceph.client.admin.keyring

    # Create monmap
    ${pkgs.ceph.out}/bin/monmaptool --create --add a ${monIp} \
      --fsid ${fsid} /tmp/monmap

    # Initialize mon filesystem
    chown -R ceph:ceph /tmp/ceph.mon.keyring /tmp/monmap
    chown ceph:ceph /etc/ceph/ceph.client.admin.keyring
    ${pkgs.util-linux}/bin/runuser -u ceph -- \
      ${pkgs.ceph.out}/bin/ceph-mon --mkfs -i a --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring

    # Copy keyring to where systemd ConditionPathExists expects it
    cp /tmp/ceph.mon.keyring /var/lib/ceph/mon/ceph-a/keyring
    chown ceph:ceph /var/lib/ceph/mon/ceph-a/keyring

    touch /var/lib/ceph/mon/ceph-a/done
    touch "$SENTINEL"
  '';

  # ─────────────────────────────────────────────────────────────
  # Phase 2: after mon is up, create mgr + osd keyrings/fs
  # ─────────────────────────────────────────────────────────────
  phase2 = pkgs.writeShellScript "ceph-bootstrap-phase2" ''
    set -euo pipefail
    SENTINEL=/var/lib/ceph/.phase2-done
    [ -f "$SENTINEL" ] && exit 0

    # Wait for mon to be reachable
    for i in $(seq 1 60); do
      if ${pkgs.ceph.out}/bin/ceph -s --connect-timeout 5 >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Enable msgr2
    ${pkgs.ceph.out}/bin/ceph mon enable-msgr2
    ${pkgs.ceph.out}/bin/ceph config set mon auth_allow_insecure_global_id_reclaim false

    # Create mgr keyring
    mkdir -p /var/lib/ceph/mgr/ceph-a
    ${pkgs.ceph.out}/bin/ceph auth get-or-create mgr.a \
      mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
      > /var/lib/ceph/mgr/ceph-a/keyring
    chown -R ceph:ceph /var/lib/ceph/mgr/ceph-a

    # OSD setup
    mkdir -p /var/lib/ceph/osd/ceph-0
    OSD_KEY=$(${pkgs.ceph.out}/bin/ceph-authtool --gen-print-key)
    OSD_UUID=$(${pkgs.util-linux}/bin/uuidgen)

    ${pkgs.ceph.out}/bin/ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-0/keyring \
      --name osd.0 --add-key "$OSD_KEY"

    # Register OSD with the mon
    echo "{\"cephx_secret\": \"$OSD_KEY\"}" | \
      ${pkgs.ceph.out}/bin/ceph osd new "$OSD_UUID" -i -

    # Link block device and init bluestore
    echo bluestore > /var/lib/ceph/osd/ceph-0/type
    ln -sf /dev/zvol/zroot/ceph-osd0 /var/lib/ceph/osd/ceph-0/block

    ${pkgs.ceph.out}/bin/ceph-osd -i 0 --mkfs --osd-uuid "$OSD_UUID"

    chown -R ceph:disk /var/lib/ceph/osd/ceph-0

    # Explicitly start mgr and osd because systemd may have already
    # evaluated their ConditionPathExists and skipped them in this
    # transaction (keyrings were created after planning).
    systemctl start ceph-mgr-a.service ceph-osd-0.service

    touch "$SENTINEL"
  '';

  # ─────────────────────────────────────────────────────────────
  # Phase 3: after OSD is up, create pool and tune for single node
  # ─────────────────────────────────────────────────────────────
  phase3 = pkgs.writeShellScript "ceph-bootstrap-pool" ''
    set -euo pipefail
    SENTINEL=/var/lib/ceph/.phase3-done
    [ -f "$SENTINEL" ] && exit 0

    # Wait for HEALTH_OK (with retries)
    for i in $(seq 1 120); do
      if ${pkgs.ceph.out}/bin/ceph -s 2>/dev/null | grep -q HEALTH_OK; then
        break
      fi
      sleep 2
    done

    # Modify crush rule to use OSD instead of host (required for single-node)
    ${pkgs.ceph.out}/bin/ceph osd getcrushmap -o /tmp/crush
    ${pkgs.ceph.out}/bin/crushtool -d /tmp/crush -o /tmp/decrushed
    sed 's/step chooseleaf firstn 0 type host/step chooseleaf firstn 0 type osd/' \
      /tmp/decrushed > /tmp/modcrush
    ${pkgs.ceph.out}/bin/crushtool -c /tmp/modcrush -o /tmp/recrushed
    ${pkgs.ceph.out}/bin/ceph osd setcrushmap -i /tmp/recrushed

    # Create RBD pool
    ${pkgs.ceph.out}/bin/ceph osd pool create rbd 32 32
    ${pkgs.ceph.out}/bin/ceph osd pool application enable rbd rbd

    touch "$SENTINEL"
  '';
in
{
  # ─────────────────────────────────────────────────────────────
  # ZFS zvol for Ceph OSD backing
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
  # Ceph daemon configuration
  # ─────────────────────────────────────────────────────────────
  services.ceph = {
    enable = true;
    global = {
      fsid = fsid;
      monHost = monIp;
      monInitialMembers = "a";
    };
    extraConfig = {
      "osd pool default size" = "1";
      "osd pool default min size" = "1";
      "mon warn on pool no redundancy" = "false";
    };
    mon = {
      enable = true;
      daemons = [ "a" ];
    };
    mgr = {
      enable = true;
      daemons = [ "a" ];
    };
    osd = {
      enable = true;
      daemons = [ "0" ];
    };
    client = {
      enable = true;
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Bootstrap services
  # ─────────────────────────────────────────────────────────────
  systemd.services.ceph-bootstrap-phase1 = {
    description = "Bootstrap Ceph mon filesystem";
    before = [ "ceph-mon-a.service" ];
    after = [ "ceph-zfs-prep.service" "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph-mon.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = phase1;
    };
  };

  systemd.services.ceph-bootstrap-phase2 = {
    description = "Bootstrap Ceph mgr and osd";
    before = [ "ceph-mgr-a.service" "ceph-osd-0.service" ];
    after = [ "ceph-mon-a.service" "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = phase2;
    };
  };

  systemd.services.ceph-bootstrap-pool = {
    description = "Create Ceph RBD pool";
    before = [ "ceph.target" ];
    after = [ "ceph-osd-0.service" "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "ceph.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = phase3;
    };
  };

  # ─────────────────────────────────────────────────────────────
  # Tools
  # ─────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [ ceph ];
}
