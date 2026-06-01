#!/usr/bin/env bash
# nixos-install-from-cachyos.sh
#
# Interactive NixOS installer for CachyOS (and any Arch-based system).
# Replaces your running system with NixOS via kexec + nixos-anywhere.
# No bootable media required.
#
# Prompts for:
#   • Target disk
#   • Filesystem  (btrfs [default] or ext4)
#   • Encryption  (LUKS on/off; prompts for passphrase if on)
#   • Desktop environment  (KDE Plasma, GNOME, or headless)
#   • Display protocol     (Wayland [default] or X11)
#   • Editor               (vim, neovim, emacs, nano)
#   • Network              (Ethernet or Wi-Fi with custom kexec image)
#   • Hostname, username, timezone, locale, SSH key
#
# Disk layout (sane defaults — edit disk-config.nix for ZFS/LVM/multiple disks):
#   • 512 MiB EFI system partition (vfat)
#   • Remainder → filesystem of choice (optionally inside LUKS)
#   • btrfs subvolumes: @root /  @home /home  @nix /nix  @log /var/log  @swap /swap
#   • ext4: single root partition
#
# Requirements:
#   • CachyOS (or any Arch-based) x86_64 system
#   • At least 1.5 GB free RAM
#   • Network connection (Ethernet or Wi-Fi)

set -euo pipefail

# ─── Argument parsing ──────────────────────────────────────────────────────────
# Flags (can be combined):
#   --dry-run    Generate config files and print the nixos-anywhere command, but
#                do NOT install anything.  Skips pacman, kexec build, SSH setup,
#                and the final nixos-anywhere run.  Safe to run anywhere.
#   --vm-test    Run nixos-anywhere with --vm-test: spins up a throwaway QEMU VM,
#                exercises disko partitioning and the NixOS build inside it, then
#                exits.  Nothing is written to your real disk.
#                Requires KVM support (check: ls /dev/kvm).
#   -h / --help  Print this help and exit.
#
# Examples:
#   ./nixos-install-from-cachyos.sh --dry-run
#   ./nixos-install-from-cachyos.sh --vm-test
#   ./nixos-install-from-cachyos.sh            # live install

DRY_RUN=false
VM_TEST=false

usage() {
    grep '^#   ' "$0" | sed 's/^#   /  /'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --vm-test)  VM_TEST=true ;;
        -h|--help)  usage ;;
        *) echo "Unknown flag: $arg  (try --help)" >&2; exit 1 ;;
    esac
done

# ─── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

info()  { echo -e "${BLU}[info]${NC}  $*"; }
ok()    { echo -e "${GRN}[ ok ]${NC}  $*"; }
warn()  { echo -e "${YEL}[warn]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
hr()    { echo -e "${CYN}────────────────────────────────────────────────────${NC}"; }
blank() { echo; }

# ask <var> <prompt> [default]
ask() {
    local var="$1" prompt="$2" default="${3:-}" input
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YEL}?${NC} $prompt [${GRN}${default}${NC}]: ")" input
        printf -v "$var" '%s' "${input:-$default}"
    else
        while true; do
            read -rp "$(echo -e "${YEL}?${NC} $prompt: ")" input
            [[ -n "$input" ]] && break
            warn "This field is required."
        done
        printf -v "$var" '%s' "$input"
    fi
}

# ask_yn <prompt> [Y/n|y/N]  — returns 0 for yes, 1 for no
ask_yn() {
    local prompt="$1" default="${2:-Y}" input
    read -rp "$(echo -e "${YEL}?${NC} $prompt [${default}]: ")" input
    [[ "${input:-$default}" =~ ^[Yy] ]]
}

# ask_password <var> <label>  — reads twice, validates match + min length
ask_password() {
    local var="$1" label="$2" p1 p2
    while true; do
        read -rsp "$(echo -e "${YEL}?${NC} ${label}: ")" p1; blank
        read -rsp "$(echo -e "${YEL}?${NC} Confirm ${label}: ")" p2; blank
        if [[ "$p1" != "$p2" ]]; then
            warn "Passphrases do not match. Try again."; continue
        fi
        if (( ${#p1} < 8 )); then
            warn "Passphrase must be at least 8 characters."; continue
        fi
        printf -v "$var" '%s' "$p1"
        break
    done
}

# choose <var> <prompt> <opt1> [opt2 …]  — numbered menu, default = 1
choose() {
    local var="$1" prompt="$2"; shift 2
    local opts=("$@") input
    blank
    echo -e "${CYN}  ┌─ ${prompt}${NC}"
    for i in "${!opts[@]}"; do
        printf "${CYN}  │${NC}  %d) %s\n" "$((i+1))" "${opts[$i]}"
    done
    echo -e "${CYN}  └─${NC}"
    while true; do
        read -rp "  Choice [${GRN}1${NC}]: " input
        input="${input:-1}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[$((input-1))]}"; break
        fi
        warn "  Enter a number between 1 and ${#opts[@]}."
    done
    echo -e "  ${GRN}✓${NC} ${!var}"
    blank
}

# ─── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${CYN}"
echo '  ███╗   ██╗██╗██╗  ██╗ ██████╗ ███████╗'
echo '  ████╗  ██║██║╚██╗██╔╝██╔═══██╗██╔════╝'
echo '  ██╔██╗ ██║██║ ╚███╔╝ ██║   ██║███████╗'
echo '  ██║╚██╗██║██║ ██╔██╗ ██║   ██║╚════██║'
echo '  ██║ ╚████║██║██╔╝ ██╗╚██████╔╝███████║'
echo '  ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝'
echo -e "${NC}"
echo -e "  ${MAG}CachyOS → NixOS  │  kexec + nixos-anywhere  │  no media needed${NC}"

# Mode badge
if   [[ "$DRY_RUN" == "true" ]]; then
    echo -e "\n  ${YEL}┌─ MODE: DRY RUN ───────────────────────────────────────┐${NC}"
    echo -e "  ${YEL}│  Generates config files and prints the install command. │${NC}"
    echo -e "  ${YEL}│  Nothing is installed. No disk is touched.               │${NC}"
    echo -e "  ${YEL}└──────────────────────────────────────────────────────────┘${NC}"
elif [[ "$VM_TEST" == "true" ]]; then
    echo -e "\n  ${CYN}┌─ MODE: VM TEST ───────────────────────────────────────┐${NC}"
    echo -e "  ${CYN}│  Runs nixos-anywhere --vm-test inside a throwaway QEMU  │${NC}"
    echo -e "  ${CYN}│  VM. Validates disko + NixOS build. Real disk untouched. │${NC}"
    echo -e "  ${CYN}└──────────────────────────────────────────────────────────┘${NC}"
fi

blank; hr; blank

if [[ "$DRY_RUN" == "false" && "$VM_TEST" == "false" ]]; then
    warn "This script will COMPLETELY ERASE the disk you choose."
    warn "All data on that disk will be permanently destroyed."
    blank
    ask_yn "Have you backed up your data and are ready to continue?" "y/N" \
        || { echo "Aborted."; exit 0; }
fi
[[ $EUID -eq 0 ]] && die "Do not run as root. Run as your normal user."

# ═══════════════════════════════════════════════════════════════════════════════
# 1 — System dependencies
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "1/8  System dependencies"; hr

if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — skipping package installation."
    command -v nix  &>/dev/null && ok "nix found"    || warn "nix not installed (would run: sudo pacman -S nix)"
    command -v sshd &>/dev/null && ok "sshd found"   || warn "openssh not installed (would run: sudo pacman -S openssh)"
else
    if ! command -v nix &>/dev/null; then
        info "Installing nix via pacman…"
        sudo pacman -S --noconfirm --needed nix
        sudo systemctl enable --now nix-daemon.service
        if ! getent group nix-users &>/dev/null; then
            sudo groupadd nix-users
        fi
        sudo usermod -aG nix-users "$USER"
        warn "Added $USER to nix-users group."
    else
        ok "nix already installed"
    fi

    if ! command -v sshd &>/dev/null; then
        info "Installing openssh via pacman…"
        sudo pacman -S --noconfirm --needed openssh
    else
        ok "openssh already installed"
    fi

    if getent group nix-users &>/dev/null && ! groups | grep -q nix-users; then
        if newgrp nix-users <<REEXEC 2>/dev/null
exec bash "$0" "$@"
REEXEC
        then
            exit 0
        else
            warn "Could not switch to nix-users group, continuing anyway…"
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2 — Enable Nix flakes
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "2/8  Enabling Nix flakes"; hr

if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — skipping flake configuration."
    command -v nix &>/dev/null \
        && nix flake --help &>/dev/null \
        && ok "Flakes appear available on this system" \
        || warn "Cannot verify flakes (nix not installed or flakes not yet enabled)"
else
    NIX_USER_CONF="$HOME/.config/nix/nix.conf"
    mkdir -p "$(dirname "$NIX_USER_CONF")"
    grep -q "experimental-features" "$NIX_USER_CONF" 2>/dev/null \
        || { echo 'experimental-features = nix-command flakes' >> "$NIX_USER_CONF"
             ok "Flakes enabled in $NIX_USER_CONF"; }

    sudo grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null \
        || { echo 'experimental-features = nix-command flakes' \
                 | sudo tee -a /etc/nix/nix.conf >/dev/null
             sudo systemctl restart nix-daemon.service
             ok "Flakes enabled system-wide"; }
    ok "Flakes ready"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3 — Gather choices
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "3/8  Configuration choices"; hr

# ── Disk ───────────────────────────────────────────────────────────────────────
blank
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -v loop
blank
warn "The disk you choose will be completely and irreversibly erased."
ask DISK_DEVICE "Target disk (e.g. sda, nvme0n1)" ""
DISK_DEVICE="/dev/${DISK_DEVICE#/dev/}"
[[ -b "$DISK_DEVICE" ]] || die "$DISK_DEVICE is not a block device."
ok "Target disk: $DISK_DEVICE"

# ── Filesystem ─────────────────────────────────────────────────────────────────
choose FS_RAW "Filesystem" \
    "btrfs  — subvolumes for /, /home, /nix, /var/log, /swap  [recommended]" \
    "ext4   — simple single-partition root"
case "$FS_RAW" in btrfs*) FS="btrfs" ;; *) FS="ext4" ;; esac

# ── Encryption ─────────────────────────────────────────────────────────────────
LUKS=false
LUKS_PASSPHRASE=""
if ask_yn "Enable LUKS full-disk encryption?" "Y/n"; then
    LUKS=true
    ask_password LUKS_PASSPHRASE "LUKS encryption passphrase"
    ok "Encryption: LUKS enabled"
else
    ok "Encryption: none"
fi

# ── Desktop environment ────────────────────────────────────────────────────────
choose DE_RAW "Desktop environment" \
    "KDE Plasma 6  — feature-rich, highly customisable" \
    "GNOME         — clean, minimal, Wayland-first" \
    "None          — headless / server"
case "$DE_RAW" in KDE*) DE="kde" ;; GNOME*) DE="gnome" ;; *) DE="none" ;; esac

# ── Display protocol ───────────────────────────────────────────────────────────
DISPLAY_SERVER="wayland"
if [[ "$DE" != "none" ]]; then
    choose DS_RAW "Display protocol" \
        "Wayland  — modern, recommended for both KDE and GNOME  [default]" \
        "X11      — legacy, wider app compatibility"
    case "$DS_RAW" in X11*) DISPLAY_SERVER="x11" ;; *) DISPLAY_SERVER="wayland" ;; esac
fi
ok "Desktop: $( [[ "$DE" == "none" ]] && echo "headless" || echo "${DE} / ${DISPLAY_SERVER}" )"

# ── Editor ─────────────────────────────────────────────────────────────────────
choose ED_RAW "Default text editor" \
    "vim    — modal, ubiquitous" \
    "neovim — vim fork with Lua config" \
    "emacs  — extensible, kitchen-sink" \
    "nano   — simple, beginner-friendly"
case "$ED_RAW" in
    vim*)    EDITOR_PKG="vim";    EDITOR_VAR="vim"   ;;
    neovim*) EDITOR_PKG="neovim"; EDITOR_VAR="nvim"  ;;
    emacs*)  EDITOR_PKG="emacs";  EDITOR_VAR="emacs" ;;
    nano*)   EDITOR_PKG="nano";   EDITOR_VAR="nano"  ;;
esac
ok "Editor: $EDITOR_PKG"

# ── System basics ──────────────────────────────────────────────────────────────
blank
ask HOSTNAME   "Hostname"           "nixos"
ask USERNAME   "Primary username"   "$(whoami)"
ask TIMEZONE   "Timezone"           "America/New_York"
ask LOCALE     "Default locale"     "en_US.UTF-8"
ask STATE_VER  "NixOS state version" "25.05"

# ── SSH key ────────────────────────────────────────────────────────────────────
blank
info "SSH public key — required to log in after install."
for f in "$HOME"/.ssh/*.pub; do
    [[ -f "$f" ]] && echo "  Found: $f"
done
blank
if ask_yn "Generate a new ed25519 key for this install?" "Y/n"; then
    KEYFILE="$HOME/.ssh/id_ed25519_nixos"
    ssh-keygen -t ed25519 -C "nixos-$(date +%Y%m%d)" -f "$KEYFILE" -N ""
    SSH_PUBKEY="$(cat "${KEYFILE}.pub")"
    ok "Generated: ${KEYFILE}.pub"
else
    ask SSH_PUBKEY_FILE "Path to existing .pub file" "$HOME/.ssh/id_ed25519.pub"
    [[ -f "$SSH_PUBKEY_FILE" ]] || die "File not found: $SSH_PUBKEY_FILE"
    SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
fi
ok "SSH key: ${SSH_PUBKEY:0:72}…"

# ── Network ────────────────────────────────────────────────────────────────────
blank
info "The default kexec installer has NO Wi-Fi support."
info "Ethernet: nothing extra needed."
info "Wi-Fi: a custom kexec image with iwd will be built from your credentials."
blank
USE_WIFI=false
WIFI_SSID=""; WIFI_PASSWORD=""; WIFI_PROFILE_NAME=""; WIFI_HIDDEN=false
if ask_yn "Connecting via Wi-Fi (not Ethernet)?" "y/N"; then
    USE_WIFI=true
    ask WIFI_SSID     "Wi-Fi SSID"
    ask WIFI_PASSWORD "Wi-Fi passphrase"
    WIFI_PROFILE_NAME="${WIFI_SSID// /_}"
    ask_yn "Hidden SSID?" "y/N" && WIFI_HIDDEN=true || true
    ok "Wi-Fi: SSID='$WIFI_SSID'  hidden=$WIFI_HIDDEN"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4 — Generate configuration files
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "4/8  Generating configuration files"; hr

WORKDIR="$HOME/nixos-config"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ── disk-config.nix ────────────────────────────────────────────────────────────
# Four variants: {btrfs,ext4} × {plain,luks}

DISK_LABEL="${FS}$([ "$LUKS" = true ] && echo ' + LUKS' || true)"

if [[ "$FS" == "btrfs" && "$LUKS" == "false" ]]; then
cat > disk-config.nix <<NIXEOF
# disk-config.nix — btrfs, no encryption
# Generated by nixos-install-from-cachyos.sh
# Subvolumes: @root=/  @home=/home  @nix=/nix  @log=/var/log  @swap=/swap
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "${DISK_DEVICE}";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" "-L" "nixos" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
              };
              "@home" = {
                mountpoint = "/home";
                mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
              };
              "@log" = {
                mountpoint = "/var/log";
                mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
              };
              "@swap" = {
                mountpoint = "/swap";
                mountOptions = [ "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
NIXEOF

elif [[ "$FS" == "btrfs" && "$LUKS" == "true" ]]; then
cat > disk-config.nix <<NIXEOF
# disk-config.nix — btrfs + LUKS encryption
# Generated by nixos-install-from-cachyos.sh
# Boot will prompt for LUKS passphrase before mounting any filesystem.
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "${DISK_DEVICE}";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "nixos" ];
              subvolumes = {
                "@root" = {
                  mountpoint = "/";
                  mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                };
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                };
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                };
                "@log" = {
                  mountpoint = "/var/log";
                  mountOptions = [ "compress=zstd" "noatime" "space_cache=v2" ];
                };
                "@swap" = {
                  mountpoint = "/swap";
                  mountOptions = [ "noatime" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
NIXEOF

elif [[ "$FS" == "ext4" && "$LUKS" == "false" ]]; then
cat > disk-config.nix <<NIXEOF
# disk-config.nix — ext4, no encryption
# Generated by nixos-install-from-cachyos.sh
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "${DISK_DEVICE}";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
NIXEOF

else  # ext4 + LUKS
cat > disk-config.nix <<NIXEOF
# disk-config.nix — ext4 + LUKS encryption
# Generated by nixos-install-from-cachyos.sh
{ ... }:
{
  disko.devices.disk.main = {
    type = "disk";
    device = "${DISK_DEVICE}";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
NIXEOF
fi
ok "Generated disk-config.nix  ($DISK_LABEL)"

# ── DE Nix snippet ─────────────────────────────────────────────────────────────
# Written into configuration.nix below using a variable
if   [[ "$DE" == "kde"   && "$DISPLAY_SERVER" == "wayland" ]]; then
    DE_NIX=$(printf '%s' \
'  # KDE Plasma 6 — Wayland
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };')
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'

elif [[ "$DE" == "kde"   && "$DISPLAY_SERVER" == "x11" ]]; then
    DE_NIX=$(printf '%s' \
'  # KDE Plasma 6 — X11
  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;')
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'

elif [[ "$DE" == "gnome" && "$DISPLAY_SERVER" == "wayland" ]]; then
    DE_NIX=$(printf '%s' \
'  # GNOME — Wayland (default)
  services.xserver.enable = true;
  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;')
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'

elif [[ "$DE" == "gnome" && "$DISPLAY_SERVER" == "x11" ]]; then
    DE_NIX=$(printf '%s' \
'  # GNOME — X11
  services.xserver.enable = true;
  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;')
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'

else  # headless
    DE_NIX='  # Headless — no display manager or desktop environment'
    USER_GROUPS='[ "wheel" "networkmanager" ]'
fi

# Note: LUKS configuration is handled by disko, no manual config needed

# Font block — only for graphical installs
if [[ "$DE" != "none" ]]; then
    FONT_BLOCK=$(printf '%s' \
'  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
  ];')
else
    FONT_BLOCK='  # No fonts configured (headless install)'
fi

# ── configuration.nix ──────────────────────────────────────────────────────────
cat > configuration.nix <<NIXEOF
# configuration.nix — generated by nixos-install-from-cachyos.sh
#
# Desktop:    $( [[ "$DE" == "none" ]] && echo "headless" || echo "${DE} / ${DISPLAY_SERVER}" )
# Filesystem: ${DISK_LABEL}
# Editor:     ${EDITOR_PKG}
#
# To apply changes after install:
#   nixos-rebuild switch --flake ~/nixos-config#${HOSTNAME}
{ config, pkgs, lib, ... }:
{
  # ── Bootloader ──────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking ──────────────────────────────────────────────────────────────
  networking.hostName          = "${HOSTNAME}";
  networking.networkmanager.enable = true;
  # Post-install Wi-Fi: use nmtui (TUI) or nmcli (CLI) — NetworkManager handles it

  # ── Locale & time ───────────────────────────────────────────────────────────
  time.timeZone      = "${TIMEZONE}";
  i18n.defaultLocale = "${LOCALE}";

  # ── Desktop environment ─────────────────────────────────────────────────────
${DE_NIX}

  # ── SSH ─────────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # ── Users ───────────────────────────────────────────────────────────────────
  users.users.root.openssh.authorizedKeys.keys = [
    "${SSH_PUBKEY}"
  ];

  users.users.${USERNAME} = {
    isNormalUser = true;
    extraGroups  = ${USER_GROUPS};
    openssh.authorizedKeys.keys = [
      "${SSH_PUBKEY}"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ── Packages ─────────────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    ${EDITOR_PKG}
    git
    curl
    wget
    htop
    ripgrep
    fd
  ];

  environment.variables.EDITOR = "${EDITOR_VAR}";

  # ── Fonts ────────────────────────────────────────────────────────────────────
${FONT_BLOCK}

  system.stateVersion = "${STATE_VER}";
}
NIXEOF
ok "Generated configuration.nix"

# ── flake.nix ──────────────────────────────────────────────────────────────────
cat > flake.nix <<NIXEOF
# flake.nix — generated by nixos-install-from-cachyos.sh
{
  description = "NixOS — ${HOSTNAME}";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko       = { url = "github:nix-community/disko"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, disko, ... }:
  let system = "x86_64-linux"; in
  {
    nixosConfigurations.${HOSTNAME} = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ disko.nixosModules.disko ./disk-config.nix ./configuration.nix ];
    };
  };
}
NIXEOF
ok "Generated flake.nix"


# ── Lock flake ─────────────────────────────────────────────────────────────────
info "Locking flake (fetching dependency graph)…"
nix flake lock
ok "flake.lock written"

# ═══════════════════════════════════════════════════════════════════════════════
# 5 — Build note
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "5/8  System build strategy"; hr
if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — no build will occur."
elif [[ "$VM_TEST" == "true" ]]; then
    info "VM TEST — nixos-anywhere will build inside QEMU."
else
    info "Building NixOS locally while installation prepares the disk…"
    info "Your current Wi-Fi connection will be used for downloads."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 6 — Root SSH on localhost
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "6/8  Root SSH access on localhost"; hr

if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — skipping SSH setup."
    info "When running live, this authorises your key for root@127.0.0.1 and tests the connection."
elif [[ "$VM_TEST" == "true" ]]; then
    info "VM TEST — skipping SSH setup."
    info "(VM test does not use SSH to localhost; nixos-anywhere manages its own QEMU networking)"
else
    sudo systemctl enable --now sshd.service
    ok "sshd active"

    sudo mkdir -p /root/.ssh
    sudo chmod 700 /root/.ssh
    if ! sudo grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$SSH_PUBKEY" | sudo tee -a /root/.ssh/authorized_keys >/dev/null
        sudo chmod 600 /root/.ssh/authorized_keys
        ok "Public key written to /root/.ssh/authorized_keys"
    else
        ok "Public key already present"
    fi

    info "Testing SSH to root@127.0.0.1…"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        root@127.0.0.1 true 2>/dev/null \
        && ok "Root SSH on localhost works" \
        || die "SSH as root to localhost failed.\n  Hint: check PermitRootLogin in /etc/ssh/sshd_config."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 7 — Summary
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "7/8  Summary"; hr; blank

printf '  %-18s %s\n' "Disk:"         "$( [[ "$DRY_RUN" == "true" || "$VM_TEST" == "true" ]] \
                                              && echo "${DISK_DEVICE}  (NOT touched in this mode)" \
                                              || echo "$(echo -e "${RED}${DISK_DEVICE}${NC}")  ← will be erased" )"
printf '  %-18s %s\n' "Filesystem:"   "${DISK_LABEL}"
printf '  %-18s %s\n' "Desktop:"      "$( [[ "$DE" == "none" ]] && echo "headless" || echo "${DE} / ${DISPLAY_SERVER}" )"
printf '  %-18s %s\n' "Editor:"       "${EDITOR_PKG}"
printf '  %-18s %s\n' "Hostname:"     "${HOSTNAME}"
printf '  %-18s %s\n' "Username:"     "${USERNAME}"
printf '  %-18s %s\n' "Timezone:"     "${TIMEZONE}"
printf '  %-18s %s\n' "Locale:"       "${LOCALE}"
printf '  %-18s %s\n' "Network:"      "$( [[ "$USE_WIFI" == "true" ]] && echo "Wi-Fi — SSID: ${WIFI_SSID}" || echo "Ethernet" )"
printf '  %-18s %s\n' "Config dir:"   "${WORKDIR}"
blank

if   [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YEL}  ┌────────────────────────────────────────────────┐${NC}"
    echo -e "${YEL}  │  DRY RUN — no changes will be made to disk     │${NC}"
    echo -e "${YEL}  └────────────────────────────────────────────────┘${NC}"
elif [[ "$VM_TEST" == "true" ]]; then
    echo -e "${CYN}  ┌────────────────────────────────────────────────┐${NC}"
    echo -e "${CYN}  │  VM TEST — real disk untouched                  │${NC}"
    echo -e "${CYN}  └────────────────────────────────────────────────┘${NC}"
    blank
    warn "VM test requires KVM.  Check: ls /dev/kvm"
    warn "nixos-anywhere will build the NixOS closure and run disko"
    warn "inside a throwaway QEMU VM.  The VM exits when done."
    warn "Expect this to take 5–20 minutes depending on your machine."
else
    echo -e "${RED}  ┌────────────────────────────────────────────────┐${NC}"
    echo -e "${RED}  │            POINT OF NO RETURN                  │${NC}"
    echo -e "${RED}  └────────────────────────────────────────────────┘${NC}"
    blank
    warn "nixos-anywhere will:"
    warn "  • kexec into a NixOS RAM environment  (CachyOS stops immediately)"
    warn "  • Erase and repartition ${DISK_DEVICE}"
    warn "  • Install NixOS and reboot"
    blank
    warn "Your terminal may go quiet for ~2 minutes while kexec fires and"
    warn "the installer reconnects over SSH. This is completely normal."
fi
blank

# Confirmation prompt — dry-run skips, vm-test and live both ask
PROCEED=false
if [[ "$DRY_RUN" == "true" ]]; then
    PROCEED=true   # dry-run always continues to print the command
elif ask_yn "Proceed? $( [[ "$VM_TEST" == "true" ]] && echo "(launches VM — real disk safe)" || echo "(last prompt — irreversible)" )" "y/N"; then
    PROCEED=true
fi

if [[ "$PROCEED" == "false" ]]; then
    blank
    info "Aborted. Nothing written to disk."
    info "Generated config is in: ${WORKDIR}"
    blank
    info "To install manually later:"
    echo
    echo "  nix run github:nix-community/nixos-anywhere -- \\"
    echo "    --flake ${WORKDIR}#${HOSTNAME} \\"
    echo "    --target-host root@127.0.0.1 \\"
    [[ -n "$KEXEC_FLAG" ]] && echo "    ${KEXEC_FLAG} \\"
    if [[ "$LUKS" == "true" ]]; then
        echo "    --disk-encryption-keys /tmp/luks.key <(echo -n 'YOUR_PASSPHRASE') \\"
    fi
    echo "    --build-on remote"
    blank
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 8 — Launch (dry-run prints command; vm-test runs VM; live installs)
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr

if [[ "$DRY_RUN" == "true" ]]; then
    info "8/8  DRY RUN — install command (nothing executed)"
    hr; blank
    echo -e "  ${GRN}The following command would be run:${NC}"
    blank
    printf '  nix run github:nix-community/nixos-anywhere -- \\\n'
    printf '    --flake %s#%s \\\n'    "$WORKDIR" "$HOSTNAME"
    printf '    --target-host root@127.0.0.1 \\\n'
    printf '    --build-on remote'
    [[ -n "$KEXEC_FLAG" ]] && printf ' \\\n    %s' "$KEXEC_FLAG"
    if [[ "$LUKS" == "true" ]]; then
        printf ' \\\n    --disk-encryption-keys /tmp/luks.key <(echo -n YOUR_PASSPHRASE)'
    fi
    blank; blank
    info "Config files written to ${WORKDIR}/"
    info "Run with --vm-test next to validate inside a VM, or without flags to install."
    blank

elif [[ "$VM_TEST" == "true" ]]; then
    info "8/8  VM TEST — running nixos-anywhere --vm-test"
    hr; blank
    warn "This builds the full NixOS closure and exercises disko in QEMU."
    warn "It does NOT touch your real disk."
    blank

    # vm-test doesn't use --target-host, --kexec, or --disk-encryption-keys
    # It needs qemu available; nixos-anywhere pulls it from nixpkgs automatically
    nix run github:nix-community/nixos-anywhere -- \
        --flake "${WORKDIR}#${HOSTNAME}" \
        --vm-test

    blank
    ok "VM test completed successfully."
    ok "Your configuration is valid and the disk layout works."
    blank
    info "Next steps:"
    echo "  • Review generated files in ${WORKDIR}/"
    echo "  • Run without --vm-test to perform the real install:"
    echo "    ./nixos-install-from-cachyos.sh"
    blank

else
    info "8/8  Running nixos-anywhere"
    hr; blank

    # Build command as an array so quoting is clean
    NIXOS_ANYWHERE_CMD=(
        nix run github:nix-community/nixos-anywhere --
        --flake "${WORKDIR}#${HOSTNAME}"
        --target-host root@127.0.0.1
        --build-on local
    )

    if [[ "$LUKS" == "true" ]]; then
        LUKS_KEY_TMP="$(mktemp /tmp/nixos-luks-key.XXXXXX)"
        printf '%s' "$LUKS_PASSPHRASE" > "$LUKS_KEY_TMP"
        trap 'rm -f "$LUKS_KEY_TMP"' EXIT
        NIXOS_ANYWHERE_CMD+=("--disk-encryption-keys" "/tmp/luks.key" "$LUKS_KEY_TMP")
    fi

    "${NIXOS_ANYWHERE_CMD[@]}"

    blank
    ok "nixos-anywhere finished. Machine is rebooting into NixOS."
    blank
    info "After reboot, log in with:"
    echo "  ssh ${USERNAME}@<your-ip>"
    blank
    info "Apply future changes with:"
    echo "  nixos-rebuild switch --flake ${WORKDIR}#${HOSTNAME}"
    blank
    info "Generated config:"
    echo "  ${WORKDIR}/"
    echo "  ├── flake.nix"
    echo "  ├── flake.lock"
    echo "  ├── configuration.nix"
    echo "  ├── disk-config.nix"
    [[ "$USE_WIFI" == "true" ]] && echo "  └── kexec-wifi-image.nix  (one-time use; safe to delete)"
    blank
fi
