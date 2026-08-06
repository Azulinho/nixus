# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  sops-nix = builtins.fetchTarball {
    url = "https://github.com/Mic92/sops-nix/archive/master.tar.gz";
    sha256 = "1iswdpzlyngqlipy14mjmpazx9yybvidpm4sfk74ww9jg3r849b8";
  };
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix

      # Proxmox-like feature modules
      ./modules/virtualization.nix
      ./modules/networking.nix
      ./modules/backup.nix
      "${sops-nix}/modules/sops"
      ./modules/users.nix
      ./modules/overlay-network.nix
      ./modules/ceph.nix
      ./modules/rbd-backup.nix
      ./modules/ovn.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.forceImportRoot = false;


  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.requestEncryptionCredentials = true;
  networking.hostId = "01234567";

  # Enable zswap: compressed RAM cache for swap pages
  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=zsmalloc"
  ];


  # networking.hostName = "nixos"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/London";

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

  # Swap on ZFS zvol
  swapDevices = [
    { device = "/dev/zvol/zroot/swap"; }
  ];

  # Multi-host overlay fabric (enabled now for local tenant isolation;
  # add frrPeers when second hypervisor joins)
  networking.overlayNetwork = {
    enable = true;
    localAddress = "172.16.3.4";
    frrPeers = [];
    frrAsn = 64512;
    vnis = [
      { vni = 10; bridgeName = "br-tenant-a"; overlaySubnet = "10.10.0.0/16"; }
      { vni = 20; bridgeName = "br-tenant-b"; overlaySubnet = "10.20.0.0/16"; }
    ];
    firewall.enable = true;
  };

  # OVN SDN controller (test): enables project-scoped networks in Incus
  networking.ovn = {
    enable = true;
    encapIp = "172.16.3.4";
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

