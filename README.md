# nixos-install-script

Install NixOS over your running CachyOS (or any Arch-based x86_64 system) — **no USB, no DVD, WiFi-only supported.** You stay at the keyboard and watch it work.

> **Use `install.sh`.** The older `nixos-install-from-cachyos.sh` (one-shot
> nixos-anywhere on localhost) is **superseded** — it could not work reliably on
> a single machine over WiFi (see "Why two stages" below).

## How it works (two stages)

```
STAGE 1  (run on CachyOS)        STAGE 2  (at the console, in the RAM installer)
─────────────────────────        ──────────────────────────────────────────────
./install.sh                     install-nixos
  • asks your preferences          • disko erases + partitions the disk
  • bakes your WiFi into a         • nixos-install builds the system over WiFi
    NixOS installer image         • you type `reboot`
  • kexecs into that image  ─────►   (WiFi works, full output, nothing hidden)
```

## Why two stages (this is why a one-shot script can't work here)

- **kexec kills a one-shot installer.** `nixos-anywhere` drives the install from a
  controlling process over SSH. On a *single* machine, that controller is exactly
  what `kexec` throws away — so the install dies the moment kexec fires. That's the
  classic "screen went blank for 10 minutes."
- **The stock kexec image has no WiFi.** No driver, no firmware, no credentials —
  `nixos-anywhere` [does not support WiFi](https://github.com/nix-community/nixos-anywhere).
  The RAM installer would come up with no network at all.

This project's `install.sh` fixes both: it builds a custom kexec image with `iwd` +
firmware + your WiFi credentials baked in, kexecs into it, and then you run the
install **locally at the console** — no controller to kill, network up, output visible.

## Requirements

- CachyOS / Arch x86_64, and you're **physically at the machine** (you finish at the console)
- `nix` (installed automatically via pacman if missing) and `openssl` (for password hashing)
- ~2 GB free RAM for the RAM installer
- A WiFi network you have the password for

## Quick start

```bash
# Build the installer image WITHOUT kexec-ing — confirms the heavy build works first
bash install.sh --build-only

# When you're ready: build + kexec into the installer
bash install.sh
```

After it kexecs and the installer console appears, log in as **root** (no password) and:

```bash
install-nixos      # erases the disk, installs NixOS, then tells you to reboot
```

## What you'll configure (Stage 1)

Target disk · filesystem (btrfs subvolumes or ext4) · optional LUKS · desktop (KDE / GNOME / headless)
· display protocol · editor · hostname / username / timezone / locale · login password · optional SSH key
· **WiFi SSID + passphrase** (baked into the installer image).

LUKS passphrase is **not** stored — `disko` prompts for it at the console during install.

## Generated files (`~/nixos-config/`)

- `flake.nix` — target system **and** the WiFi installer image (`packages.x86_64-linux.kexecInstaller`)
- `configuration.nix` — system settings (DE, users, packages…)
- `disk-config.nix` — disko partition/filesystem layout
- `kexec-wifi.nix` — the RAM installer: WiFi (iwd) + firmware + baked config + the `install-nixos` command
- `wifi.psk` — your WiFi profile in plaintext (**keep local, don't commit**)
- `result-kexec/` — the built installer tarball

Pinned to **nixpkgs 25.05** + matching **disko** / **nixos-images**.

## Fallback if the console misbehaves

If you added an SSH key, the installer also accepts SSH. From another device on the
same WiFi: `ssh root@<installer-ip>` (find the IP on your router), then run `install-nixos`.

## After installation

```bash
ssh <username>@<ip>                                   # log in (key or password)
nixos-rebuild switch --flake ~/nixos-config#<host>   # apply future changes
```

## Caveats / what isn't auto-tested

A real run **erases a disk**, so the end-to-end install can't be CI-tested. Two
things depend on your hardware/upstream and are worth knowing:

- **WiFi firmware**: covered for common cards (Intel `iwlwifi`, Atheros, etc.) via
  `hardware.enableRedistributableFirmware`. Some Broadcom chips need non-redistributable
  firmware and may not associate in the installer.
- **Stage 2 needs WiFi up** to download packages onto the new disk. Check with
  `iwctl station list` / `ip a` before running `install-nixos`.

## Customizing the disk layout

Edit `disk-config.nix` (ZFS, LVM, multiple disks) before running `install-nixos`.
See [disko docs](https://github.com/nix-community/disko).

## License

See LICENSE file.
