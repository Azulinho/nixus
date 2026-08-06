{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # ZFS Backup & Snapshotting
  # ============================================================================

  # Automatic ZFS snapshots (live backup support for running VMs)
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;   # every 15 minutes, keep 4
    hourly = 24;    # keep 24
    daily = 7;      # keep 7
    weekly = 4;     # keep 4
    monthly = 12;   # keep 12
  };

  # Exclude swap zvol from snapshots (snapshots of swap are useless and waste space)
  # Set imperatively: zfs set com.sun:auto-snapshot=false zroot/swap

  # Remote replication with Syncoid (Sanoid)
  # Enable after setting up SSH keys and a remote target ZFS pool.
  services.syncoid = {
    enable = false;
    # commands = {
    #   "zroot/incus" = {
    #     target = "backup-server:zroot/backups/${config.networking.hostName}/incus";
    #     recursive = true;
    #   };
    #   "zroot/root" = {
    #     target = "backup-server:zroot/backups/${config.networking.hostName}/root";
    #     recursive = true;
    #   };
    # };
    # sshKey = "/var/lib/syncoid/ssh.key";
    # user = "root";
    # group = "root";
  };

  environment.systemPackages = with pkgs; [
    sanoid    # provides both sanoid and syncoid binaries
    zfs
    zfs-autobackup  # alternative: python-based ZFS backup tool
  ];

  # ============================================================================
  # Single-file restore helpers (future roadmap item #60)
  # ============================================================================
  # To restore a single file from a remote ZFS snapshot:
  #
  #   1. Replicate or mount the remote snapshot locally (read-only):
  #      zfs send backup-server:zroot/backups/host/incus@auto-2025... | zfs recv zroot/restore
  #
  #   2. Access the files under the snapshot mount:
  #      ls /zroot/restore/.zfs/snapshot/...
  #
  #   3. Or use zfs-diff + rsync to extract individual paths.
  #
  # For automated single-file restore, investigate zfs-mount snapshots or
  # dedicated restore datasets.
  # ============================================================================
}
