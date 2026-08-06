{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # Administrative user for virtualization management
  # ============================================================================

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [
      "wheel"        # sudo access
      "incus-admin"  # full Incus administration
      "podman"       # rootless podman
    ];
    # Set a password after first login with: sudo passwd admin
    # Or define an initial hashed password here:
    # initialHashedPassword = "$y$j9T$...";
  };

  # Allow sudo for wheel group
  security.sudo.wheelNeedsPassword = true;
}
