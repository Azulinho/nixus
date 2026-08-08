#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time Ceph cluster keyring initialisation.
#
# Generates the cluster's SHARED keyrings and encrypts them into
# secrets/secrets.yaml via sops, so every node deploys the same auth
# (one cluster, not one cluster per host).
#
#   - /etc/ceph/ceph.client.admin.keyring  (cluster admin — used by incusd,
#                                           rbd-backup and the ceph CLI)
#   - /etc/ceph/ceph.mon.keyring           (mon keyring — lets joining mons
#                                           authenticate with existing mons)
#
# Run ONCE on the FIRST node (z3-nix01), BEFORE the first nixos-rebuild:
#
#   sudo scripts/ceph-init-keys.sh
#   git add secrets/secrets.yaml && git commit -m "ceph: add cluster keyrings"
#
# When node2/node3 come online: add their age public keys to .sops.yaml,
# run `sops updatekeys secrets/secrets.yaml`, re-encrypt and commit.
#
# BACK THESE KEYRINGS UP. They are the master keys of the Ceph cluster;
# /etc/ceph/ceph.client.admin.keyring on z3-nix01 + the sops age key are the
# only copies in existence.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

cd "$(dirname "$0")/.." || exit 1   # repo root

ADMIN=/etc/ceph/ceph.client.admin.keyring
MON=/etc/ceph/ceph.mon.keyring

mkdir -p /etc/ceph

if [ ! -s "$ADMIN" ]; then
  echo "Generating cluster admin keyring..."
  ceph-authtool --create-keyring "$ADMIN" --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
fi
chmod 0640 "$ADMIN"

if [ ! -s "$MON" ]; then
  # If this host already runs a Ceph cluster, adopt its mon keyring so the
  # distributed keyring matches the live cluster (joining mons must present
  # the same mon key as the existing mons).
  if [ -s /var/lib/ceph/mon/ceph-a/keyring ]; then
    echo "Adopting existing cluster's mon keyring from /var/lib/ceph/mon/ceph-a/keyring..."
    cp /var/lib/ceph/mon/ceph-a/keyring "$MON"
    chown root:ceph "$MON"
  else
    echo "Generating cluster mon keyring..."
    ceph-authtool --create-keyring "$MON" --gen-key -n mon. --cap mon 'allow *'
  fi
fi
chmod 0640 "$MON"

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/var/lib/sops/age.key}"

# sops --set expects a JSON-encoded value; perl JSON::PP does this without
# needing jq on a pre-rebuild system.
encrypt_file() {
  local key="$1" file="$2"
  local json
  json=$(perl -MJSON::PP -0777 -e 'print JSON::PP->new->canonical->encode(<>)' < "$file")
  sops --set "[\"$key\"] $json" -i secrets/secrets.yaml
  echo "  encrypted $file -> secrets/secrets.yaml [$key]"
}

echo "Encrypting keyrings into secrets/secrets.yaml..."
encrypt_file cephClientAdminKeyring "$ADMIN"
encrypt_file cephMonKeyring "$MON"

echo
echo "Done. Commit secrets/secrets.yaml."
echo "When node2/node3 come online: add their age keys to .sops.yaml,"
echo "run 'sops updatekeys secrets/secrets.yaml' and re-commit."
