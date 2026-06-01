# nixos-install-script

Interactive NixOS installer for CachyOS (and any Arch-based system). Replaces your running system with NixOS via kexec + nixos-anywhere. **No bootable media required.**

## Features

- **Zero-media install**: Uses kexec to boot into NixOS directly from your running system
- **Interactive configuration**: Walk through disk, filesystem, encryption, desktop environment, and user preferences
- **Multiple filesystem options**: btrfs with subvolumes (recommended) or ext4
- **Full-disk encryption**: Optional LUKS encryption with passphrase
- **Desktop environments**: KDE Plasma 6, GNOME, or headless/server
- **Display protocols**: Wayland (modern, default) or X11 (legacy compatibility)
- **Wi-Fi support**: Build custom kexec image with iwd for Wi-Fi-only networks
- **Safe testing**: `--vm-test` mode validates your configuration in a throwaway QEMU VM before touching your real disk
- **Dry-run mode**: `--dry-run` generates config files and prints the install command without making changes

## Requirements

- **CachyOS** (or any Arch-based x86_64 system)
- **At least 1.5 GB free RAM**
- **Network connection** (Ethernet or Wi-Fi)
- **nix and openssh packages** (script installs these if needed)

## Quick Start

### Test your configuration (recommended first step)

```bash
bash nixos-install-from-cachyos.sh --vm-test
```

This validates the NixOS build and disk layout in a QEMU VM without touching your real disk. Expects 5–20 minutes depending on your machine.

### Generate config without installing

```bash
bash nixos-install-from-cachyos.sh --dry-run
```

Generates configuration files and prints the nixos-anywhere command that would be run. Safe to run anywhere.

### Live install (no dry-run, no testing)

```bash
bash nixos-install-from-cachyos.sh
```

⚠️ **This will completely erase your chosen disk.** You'll be prompted to confirm before installation begins.

## What You'll Configure

The script prompts for:

1. **Target disk** — which disk to replace with NixOS
2. **Filesystem** — btrfs (with subvolumes: @root, @home, @nix, @log, @swap) or ext4
3. **Encryption** — optional LUKS full-disk encryption with passphrase
4. **Desktop environment** — KDE Plasma 6, GNOME, or none (headless)
5. **Display protocol** — Wayland (modern, recommended) or X11
6. **Text editor** — vim, neovim, emacs, or nano
7. **System basics** — hostname, username, timezone, locale, NixOS state version
8. **SSH key** — new ed25519 key or existing public key (required for login after install)
9. **Network** — Ethernet or Wi-Fi with custom kexec image

## Disk Layout

### EFI + btrfs (default)
```
512 MiB         → EFI system partition (vfat)
Remainder       → LUKS container (optional)
                  └─ btrfs with subvolumes:
                     ├─ @root        → /
                     ├─ @home        → /home
                     ├─ @nix         → /nix
                     ├─ @log         → /var/log
                     └─ @swap        → /swap
```

### EFI + ext4
```
512 MiB         → EFI system partition (vfat)
Remainder       → LUKS container (optional) → ext4 root (/)
```

To customize (ZFS, LVM, multiple disks): edit `disk-config.nix` in the generated config directory after running the script.

## Generated Configuration

After running the script, all configuration files are saved to `~/nixos-config/`:

- **flake.nix** — Nix flake with inputs and NixOS system configuration
- **flake.lock** — Locked dependency versions (from nixpkgs + disko)
- **configuration.nix** — System-wide NixOS settings (DE, packages, users, etc.)
- **disk-config.nix** — Disk partitioning and filesystem layout (disko)
- **kexec-wifi-image.nix** — Wi-Fi kexec installer *(generated only if Wi-Fi chosen; one-time use; safe to delete)*

## After Installation

### Log in
```bash
ssh <username>@<your-ip>
```

### Apply future changes
```bash
nixos-rebuild switch --flake ~/nixos-config#<hostname>
```

### Regenerate configuration
Re-run the installer script to regenerate any of the above files.

## Troubleshooting

### SSH connection during install hangs
The script rebuilds your system via kexec, which briefly disconnects SSH. This is normal—your terminal may go quiet for ~2 minutes while the installer reconnects. Wait for the final success message.

### Wi-Fi password prompt
If using Wi-Fi, the password is embedded in the kexec image (plaintext) for the installer. Do not commit `kexec-wifi-image.nix` to a public repository.

### Modifying disk layout
Edit `disk-config.nix` before running the final install. For ZFS, LVM, or multi-disk setups, see [disko documentation](https://github.com/nix-community/disko).

## Architecture

The script orchestrates:

1. **Dependency check** — Ensures nix, openssh, and flakes are available
2. **Interactive prompts** — Gathers user preferences
3. **Config generation** — Creates flake.nix, configuration.nix, disk-config.nix
4. **Nix build** — Compiles the NixOS closure
5. **nixos-anywhere** — Handles kexec, disko partitioning, and system installation
6. **Reboot** — Reboots into NixOS

## License

See LICENSE file.

## Development

Built with bash. Tested on CachyOS. Uses:
- [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
- [disko](https://github.com/nix-community/disko)
- [nixpkgs](https://github.com/NixOS/nixpkgs)
