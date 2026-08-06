{ config, lib, pkgs, ... }:

let
  cfg = config.services.rbdBackup;
in
{
  options.services.rbdBackup = {
    enable = lib.mkEnableOption "incremental RBD backup to S3-compatible storage via rclone";

    pool = lib.mkOption {
      type = lib.types.str;
      default = "rbd";
      description = "Ceph pool containing RBD images to back up.";
    };

    rcloneRemote = lib.mkOption {
      type = lib.types.str;
      default = "s3nas";
      description = "rclone remote name (configured via environment variables in credentialsFile).";
    };

    s3BucketPrefix = lib.mkOption {
      type = lib.types.str;
      default = "rbd-backups";
      description = "S3 bucket and/or path prefix where backups are stored.";
    };

    credentialsFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/rbd-backup/s3.env";
      description = ''
        Path to an environment file containing rclone S3 credentials.
        This file must be created manually and is NOT stored in the Nix store.
        Example contents:
          RCLONE_CONFIG_S3NAS_TYPE=s3
          RCLONE_CONFIG_S3NAS_PROVIDER=Minio
          RCLONE_CONFIG_S3NAS_ENDPOINT=http://nas.local:9000
          RCLONE_CONFIG_S3NAS_ACCESS_KEY_ID=YOUR_KEY
          RCLONE_CONFIG_S3NAS_SECRET_ACCESS_KEY=YOUR_SECRET
      '';
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 02:00:00";
      description = ''
        systemd calendar expression for the backup timer.
        Default is daily at 02:00.
      '';
    };

    retentionSnapshots = lib.mkOption {
      type = lib.types.int;
      default = 7;
      description = "Number of backup snapshots to retain on each RBD image.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Delete S3 backup files older than this many days.";
    };

    compress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Compress exports with zstd before upload.";
    };

    stagingDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/rbd-backup";
      description = "Local staging directory for backup files before S3 upload.";
    };

    imageFilter = lib.mkOption {
      type = lib.types.str;
      default = "^(container_|virtual-machine_|image_)";
      description = ''
        Regex filter applied to 'rbd ls' output. Only matching images are backed up.
        Default matches Incus instance volumes and cached base images.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.rclone ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stagingDir} 0750 root root -"
    ];

    systemd.services.rbd-backup = {
      description = "Incremental RBD backup to S3 via rclone";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "rbd-backup" ''
          set -euo pipefail

          POOL="${cfg.pool}"
          REMOTE="${cfg.rcloneRemote}"
          BUCKET="${cfg.s3BucketPrefix}"
          STAGING="${cfg.stagingDir}"
          RETAIN_SNAPS=${toString cfg.retentionSnapshots}
          RETAIN_DAYS=${toString cfg.retentionDays}
          DATE=$(date +%Y%m%d-%H%M%S)
          FILTER="${cfg.imageFilter}"
          COMPRESS=${lib.boolToString cfg.compress}

          # Load credentials if the env file exists (created manually by user)
          if [ -f "${cfg.credentialsFile}" ]; then
            set -a
            . "${cfg.credentialsFile}"
            set +a
          fi

          # Verify rclone remote is reachable
          if ! ${pkgs.rclone}/bin/rclone lsd "$REMOTE:$BUCKET" >/dev/null 2>&1; then
            echo "WARNING: Cannot reach S3 bucket '$BUCKET' via rclone remote '$REMOTE'." >&2
            echo "Check credentials in ${cfg.credentialsFile}" >&2
            # Continue anyway — rclone copy will fail later with a clearer error
          fi

          # Discover images matching the filter
          IMAGES=$(${pkgs.ceph}/bin/rbd ls --pool "$POOL" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -E "$FILTER" || true)

          if [ -z "$IMAGES" ]; then
            echo "No RBD images matched filter '$FILTER' in pool '$POOL'."
            exit 0
          fi

          for IMG in $IMAGES; do
            echo "=== Backing up $POOL/$IMG ==="

            # Find the most recent backup snapshot on this image
            LAST_SNAP=$(${pkgs.ceph}/bin/rbd snap ls --pool "$POOL" "$IMG" 2>/dev/null | \
              ${pkgs.gawk}/bin/awk '/backup-[0-9]/{print $2}' | sort | tail -n 1 || true)

            BACKUP_BASE="$STAGING/$IMG-$DATE"
            UPLOAD_PATH="$REMOTE:$BUCKET/$POOL/$IMG"

            if [ -z "$LAST_SNAP" ]; then
              echo "No previous backup snapshot — performing FULL export"
              ${pkgs.ceph}/bin/rbd export "$POOL/$IMG" "$BACKUP_BASE"
              if [ "$COMPRESS" = "true" ]; then
                ${pkgs.zstd}/bin/zstd -19 --rm "$BACKUP_BASE"
                BACKUP_FILE="$BACKUP_BASE.zst"
              else
                BACKUP_FILE="$BACKUP_BASE"
              fi
            else
              echo "Performing INCREMENTAL export from snapshot $LAST_SNAP"
              ${pkgs.ceph}/bin/rbd export-diff --from-snap "$LAST_SNAP" "$POOL/$IMG" "$BACKUP_BASE.diff"
              if [ "$COMPRESS" = "true" ]; then
                ${pkgs.zstd}/bin/zstd -19 --rm "$BACKUP_BASE.diff"
                BACKUP_FILE="$BACKUP_BASE.diff.zst"
              else
                BACKUP_FILE="$BACKUP_BASE.diff"
              fi
            fi

            # Upload to S3
            ${pkgs.rclone}/bin/rclone copy "$BACKUP_FILE" "$UPLOAD_PATH/" --s3-no-check-bucket

            # Remove staging file
            rm -f "$BACKUP_FILE"

            # Create new backup snapshot on RBD
            NEW_SNAP="backup-$DATE"
            ${pkgs.ceph}/bin/rbd snap create "$POOL/$IMG@$NEW_SNAP"

            # Retain only N most recent backup snapshots on RBD
            SNAPS=$(${pkgs.ceph}/bin/rbd snap ls --pool "$POOL" "$IMG" 2>/dev/null | \
              ${pkgs.gawk}/bin/awk '/backup-[0-9]/{print $2}' | sort || true)
            COUNT=$(echo "$SNAPS" | grep -c '^backup-' || true)
            if [ "$COUNT" -gt "$RETAIN_SNAPS" ]; then
              DEL_COUNT=$((COUNT - RETAIN_SNAPS))
              echo "$SNAPS" | head -n "$DEL_COUNT" | while read OLD; do
                echo "  Removing old RBD snapshot $IMG@$OLD"
                ${pkgs.ceph}/bin/rbd snap rm "$POOL/$IMG@$OLD" || true
              done
            fi
          done

          # S3 retention: purge backups older than retentionDays
          echo "=== Purging S3 backups older than $RETAIN_DAYS days ==="
          ${pkgs.rclone}/bin/rclone delete "$REMOTE:$BUCKET" --min-age "${toString cfg.retentionDays}d" --include "*/$POOL/*" || true

          echo "=== Backup complete ==="
        '';
      };
    };

    systemd.timers.rbd-backup = {
      description = "Timer for incremental RBD backups";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
      };
    };
  };
}
