# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  # All per-host + cluster-wide settings — see local/settings.nix.
  settingsAll = import ./local/settings.nix;

  # This host's name: the key into `settingsAll.hosts`. The file
  # /etc/nixos/hostname is a single line ("node1", "node2", …) and is
  # gitignored so each host carries its own copy in the same repo.
  hostName =
    if builtins.pathExists ./hostname then
      lib.trim (builtins.readFile ./hostname)
    else
      throw ''
        Missing /etc/nixos/hostname — create it with this host's name, e.g.:
          echo node1 > /etc/nixos/hostname
        Known hosts (keys of `hosts` in local/settings.nix):
          ${builtins.concatStringsSep " " (builtins.attrNames settingsAll.hosts)}
      '';

  # Per-host values for THIS host, merged with the cluster-wide keys.
  # Exposed to every module as the `settings` argument via _module.args.
  settings = { hostName = hostName; }
    // (settingsAll.hosts.${hostName} or (throw ''
         local/settings.nix has no entry for host "${hostName}".
         Add a `hosts.${hostName} = { … };` block (copy an existing node).
       ''))
    // removeAttrs settingsAll [ "hosts" ];

  sops-nix = builtins.fetchTarball {
    url = "https://github.com/Mic92/sops-nix/archive/master.tar.gz";
    sha256 = "1iswdpzlyngqlipy14mjmpazx9yybvidpm4sfk74ww9jg3r849b8";
  };
in
{
  # Make local/settings.nix available to all modules as `settings`.
  _module.args.settings = settings;

  imports =
    [ # Per-host hardware scan (nixos-generate-config output), keyed by hostname.
      (if builtins.pathExists ./local/${hostName}-hardware-configuration.nix then
         ./local/${hostName}-hardware-configuration.nix
       else
         throw ''
           Missing local/${hostName}-hardware-configuration.nix — generate it on this host and commit it:
             nixos-generate-config --dir /etc/nixos/local
             mv /etc/nixos/local/hardware-configuration.nix /etc/nixos/local/${hostName}-hardware-configuration.nix
         '')

      # Proxmox-like feature modules
      ./modules/virtualization.nix
      ./modules/networking.nix
      ./modules/backup.nix
      "${sops-nix}/modules/sops"
      ./modules/users.nix
      ./modules/ceph.nix
      ./modules/rbd-backup.nix
      ./modules/ovn.nix
      ./modules/incus-dns.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.forceImportRoot = false;


  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.requestEncryptionCredentials = true;
  networking.hostId = settings.hostId;

  # Enable zswap: compressed RAM cache for swap pages
  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=zsmalloc"
  ];


  # networking.hostName comes from local/settings.nix (per-host).
  networking.hostName = settings.hostName;

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;

  # Set your time zone (per-host value from local/settings.nix).
  time.timeZone = settings.timeZone;

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;


  

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
  #   packages = with pkgs; [
  #     tree
  #   ];
  # };

  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
     vim
     wget
     pi-coding-agent
     opencode
     git
     tmux
     sops
     age
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Per-project DNS for Incus: serves <instance>.<project>.incus-cluster1.mydomain
  # through the uplink dnsmasq (see modules/incus-dns.nix).
  services.incusDns = {
    enable = true;
    zone = settings.dnsZone;
  };

  # Swap on ZFS zvol
  swapDevices = [
    { device = "/dev/zvol/zroot/swap"; }
  ];

  # OVN SDN: every node is BOTH central AND compute. All three hosts run the
  # NB/SB DBs + ovn-northd (central) and the local ovn-controller (compute) —
  # the three centrals form a RAFT-quorum control plane (survives 1 failure).
  #
  # All per-host values (nodeIndex, localAddress, …) come from local/settings.nix —
  # that is the ONLY file to edit when cloning to node2/node3.
  networking.ovn = {
    enable = true;
    role = "central";                      # central also runs the local controller
    centralNodes = settings.centralNodes;  # same three-IP list on every host
    nodeIndex = settings.nodeIndex;        # ← per-host (local/settings.nix)
    localAddress = settings.localAddress;  # ← per-host (local/settings.nix)
  };

  # Incremental RBD backups to S3-compatible NAS
  services.rbdBackup = {
    enable = true;
    pool = "rbd";
    rcloneRemote = "s3nas";
    s3BucketPrefix = "rbd-backups";
    schedule = "*-*-* 02:00:00";
    retentionSnapshots = 7;
    retentionDays = 30;
    compress = true;
    credentialsFile = config.sops.secrets.rbdBackupS3Env.path;
  };

  # Secrets management via sops-nix
  sops.defaultSopsFile = ./secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops/age.key";
  sops.secrets.rbdBackupS3Env = {};

  # Enable modern Nix CLI (flakes + nix-command)
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}

