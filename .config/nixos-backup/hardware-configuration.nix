{ lib, modulesPath, ... }: {
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "uas" "usb_storage" "sd_mod" ];
  boot.initrd.luks.devices."luks-1c9217e1-b8ed-47a7-8c70-b576ff25b915".device = "/dev/null";
  fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/null"; fsType = "vfat"; };
  swapDevices = [ ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
