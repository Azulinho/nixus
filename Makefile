# Makefile for the NixOS Hypervisor Cluster
#
# Wraps the most common operator tasks from README.md so you don't have to
# remember the exact commands. Run `make help` for a full list.
#
# Paths that need the repo root are anchored via ROOT, so targets work even
# when make is invoked from a subdirectory (e.g. /etc/nixos/modules).

# NixOS has no /bin/bash — let make find bash via PATH.
SHELL       := bash
ROOT        := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
SECRETS     := $(ROOT)/secrets/secrets.yaml

# Where this host's age private key lives (same path sops-nix reads,
# sops.age.keyFile in configuration.nix). Override per-invocation with
# `make sops-updatekeys SOPS_AGE_KEY_FILE=/path/to/key`.
SOPS_AGE_KEY_FILE ?= /var/lib/sops/age.key

# This host's name (/etc/nixos/hostname, gitignored, one line).
HOSTNAME := $(strip $(shell cat $(ROOT)/hostname 2>/dev/null || echo unknown))

.DEFAULT_GOAL := help

.PHONY: help rebuild rebuild-trace hardware whoami \
	sops-edit sops-updatekeys sops-init secrets-verify \
	incus-list incus-storage incus-profiles incus-cluster \
	ceph-status ceph-pools ceph-wipe rbd-list rbd-usage zpool-status zfs-snapshots \
	firewall ovn-status ovn-active ovn-nb ovn-sb ovs-show \
	backup-run backup-log backup-status dns-refresh timers \
	status

help: ## List all available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*##' '{printf "  %-18s %s\n", $$1, $$2}'

# ---------------------------------------------------------------- config
# README §3.3, §9.1, §15.1
rebuild: ## Apply config changes to the running system (sudo nixos-rebuild switch)
	sudo nixos-rebuild switch

rebuild-trace: ## Rebuild with --show-trace (diagnostics on failure)
	sudo nixos-rebuild switch --show-trace

hardware: ## Regenerate local/hardware-configuration.nix for this host
	sudo nixos-generate-config --dir $(ROOT)/local
	sudo mv $(ROOT)/local/hardware-configuration.nix \
		$(ROOT)/local/$(HOSTNAME)-hardware-configuration.nix

whoami: ## Which host am I
	@cat $(ROOT)/hostname

# ---------------------------------------------------------------- secrets
# README §3.4 (sops-nix) — age key lives at /var/lib/sops/age.key
sops-edit: ## Edit secrets/secrets.yaml (sops encrypts on save)
	sops $(SECRETS)

sops-updatekeys: ## Re-encrypt secrets for every key in .sops.yaml (new host: add its age key first)
	SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops updatekeys $(SECRETS)

sops-init: ## Symlink the host age key into ~/.config/sops/age (README §3.4 fallback)
	mkdir -p $${HOME}/.config/sops/age
	ln -sf /var/lib/sops/age.key $${HOME}/.config/sops/age/keys.txt
	@echo "Age key linked — sops now works without SOPS_AGE_KEY_FILE."

secrets-verify: ## Secrets round-trip: restart sops-nix and read the decrypted S3 env
	sudo systemctl restart sops-nix
	sudo cat /run/secrets/rbdBackupS3Env

# ---------------------------------------------------------------- incus
# README §6, §15.2
incus-list: ## List instances
	incus list

incus-storage: ## List storage pools (ceph = RBD)
	incus storage list

incus-profiles: ## List profiles (default, ceph, router)
	incus profile list

incus-cluster: ## Incus cluster membership
	incus cluster list

# ---------------------------------------------------------------- storage
# README §4, §15.3
ceph-status: ## Ceph cluster health (expect HEALTH_OK)
	sudo ceph -s

ceph-pools: ## Ceph pools (rbd, .mgr)
	sudo ceph osd pool ls

rbd-list: ## List RBD images in the rbd pool
	sudo rbd ls --pool rbd

rbd-usage: ## RBD space usage
	sudo rbd du --pool rbd

zpool-status: ## ZFS pool health
	sudo zpool status

zfs-snapshots: ## List ZFS snapshots
	zfs list -t snapshot

# ---------------------------------------------------------------- ceph-wipe
# Destroys LOCAL Ceph state so a node can be re-bootstrapped from scratch.
# Only touches this host's daemons; cluster data on other nodes is unaffected.
ceph-wipe: ## Wipe local Ceph state (sentinels, mon/mgr/osd dirs, zvols)
	@echo "Stopping Ceph services..."
	sudo systemctl stop ceph.target || true
	sudo systemctl stop ceph-mon.target ceph-mgr.target ceph-osd.target || true
	@echo "Removing bootstrap sentinels..."
	sudo rm -f /var/lib/ceph/.phase1-done /var/lib/ceph/.phase2-done /var/lib/ceph/.phase3-done
	@echo "Removing local daemon directories..."
	sudo rm -rf /var/lib/ceph/mon /var/lib/ceph/mgr /var/lib/ceph/osd
	@echo "Destroying Ceph OSD zvols..."
	@for vol in $$(zfs list -H -o name -t volume | grep '^zroot/ceph-osd'); do \
		echo "  destroying $$vol"; \
		sudo zfs destroy "$$vol" 2>/dev/null || true; \
	done
	@echo "Ceph wipe complete. Run 'make rebuild' to re-bootstrap."

# ---------------------------------------------------------------- network
# README §5, §12.4, §15.4
firewall: ## Show the host nftables ruleset
	sudo nft list ruleset

ovn-active: ## Are the key services running? (README §11 daily check)
	systemctl is-active incus nftables systemd-networkd ovn-northd ovn-controller

ovn-status: ## OVN service status (DBs + northd + controller)
	sudo systemctl status ovn-nb-db ovn-sb-db ovn-northd ovn-controller

ovn-nb: ## OVN logical topology (northbound)
	sudo ovn-nbctl show

ovn-sb: ## OVN chassis + logical ports (southbound)
	sudo ovn-sbctl show

ovs-show: ## Open vSwitch state
	sudo ovs-vsctl show

# ---------------------------------------------------------------- backup
# README §8.1, §15.5
backup-run: ## Trigger an RBD backup now
	sudo systemctl start rbd-backup.service

backup-log: ## Follow the backup log
	sudo journalctl -u rbd-backup.service -f

backup-status: ## Last backup run (look for 'Backup complete')
	sudo journalctl -u rbd-backup.service -e --no-pager

timers: ## List rbd/zfs/incus-dns timers
	systemctl list-timers | grep -E 'rbd|zfs|incus-dns'

dns-refresh: ## Force per-project DNS record refresh (README §7.2)
	sudo systemctl restart incus-dns-refresh.service

# ---------------------------------------------------------------- health
# README §11 (Routine Maintenance)
status: ## Daily health summary: services, backup, ceph, zfs, disk
	@echo "=== Host: $(HOSTNAME) ==="
	@echo
	@echo "--- Services ---"
	systemctl is-active incus nftables systemd-networkd ovn-northd ovn-controller
	@echo
	@echo "--- Last backup run ---"
	@sudo journalctl -u rbd-backup.service -e --no-pager -n 5
	@echo
	@echo "--- Ceph ---"
	@sudo ceph -s
	@echo
	@echo "--- ZFS ---"
	@sudo zpool status
	@echo
	@echo "--- Disk usage ---"
	@df -h /
