#!/usr/bin/env bash
# install.sh — reliable two-stage NixOS installer for CachyOS (WiFi, no media)
#
# WHY TWO STAGES (read this — it's why the old one-shot script failed):
#   nixos-anywhere drives an install over SSH *from a controlling process*. On a
#   single machine that controller is the very thing kexec throws away, so the
#   install dies the instant kexec fires (→ blank screen forever). And the stock
#   kexec image has no WiFi driver/firmware/credentials, so even if it survived,
#   the RAM installer would come up with no network.
#
#   This script avoids both problems:
#     STAGE 1 (here, on CachyOS): build a NixOS *installer* image with YOUR WiFi
#             baked in (iwd + firmware + credentials), then kexec into it.
#     STAGE 2 (at the console, in that installer): run `install-nixos` and WATCH
#             disko partition the disk and nixos-install build the system over
#             WiFi. No second kexec, nothing to kill, full output the whole time.
#
# Requirements:
#   • CachyOS / Arch x86_64, physically at the keyboard (you'll use the console)
#   • nix (this script installs it via pacman if missing)
#   • enough RAM for the RAM installer (~2 GB free recommended)
#
# Flags:
#   --build-only   Generate config + build the installer image, but DO NOT kexec.
#                  Lets you confirm the heavy build succeeds before committing.
#   -h | --help    Show this help.

set -euo pipefail

BUILD_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown flag: $arg (try --help)" >&2; exit 1 ;;
    esac
done

# ─── UI helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'
info()  { echo -e "${BLU}[info]${NC}  $*"; }
ok()    { echo -e "${GRN}[ ok ]${NC}  $*"; }
warn()  { echo -e "${YEL}[warn]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
hr()    { echo -e "${CYN}────────────────────────────────────────────────────${NC}"; }
blank() { echo; }

ask() {  # ask <var> <prompt> [default]
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
ask_yn() {  # ask_yn <prompt> [default]
    local prompt="$1" default="${2:-Y}" input
    read -rp "$(echo -e "${YEL}?${NC} $prompt [${default}]: ")" input
    [[ "${input:-$default}" =~ ^[Yy] ]]
}
ask_password() {  # ask_password <var> <label>
    local var="$1" label="$2" p1 p2
    while true; do
        read -rsp "$(echo -e "${YEL}?${NC} ${label}: ")" p1; blank
        read -rsp "$(echo -e "${YEL}?${NC} Confirm ${label}: ")" p2; blank
        [[ "$p1" != "$p2" ]] && { warn "Do not match. Try again."; continue; }
        (( ${#p1} < 8 ))   && { warn "Min 8 characters."; continue; }
        printf -v "$var" '%s' "$p1"; break
    done
}
choose() {  # choose <var> <prompt> <opt1> [opt2 …]
    local var="$1" prompt="$2"; shift 2
    local opts=("$@") input
    blank; echo -e "${CYN}  ┌─ ${prompt}${NC}"
    for i in "${!opts[@]}"; do printf "${CYN}  │${NC}  %d) %s\n" "$((i+1))" "${opts[$i]}"; done
    echo -e "${CYN}  └─${NC}"
    while true; do
        read -rp "  Choice [${GRN}1${NC}]: " input; input="${input:-1}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input>=1 && input<=${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[$((input-1))]}"; break
        fi
        warn "  Enter 1–${#opts[@]}."
    done
    echo -e "  ${GRN}✓${NC} ${!var}"; blank
}

# ─── Banner ──────────────────────────────────────────────────────────────────
clear
echo -e "${CYN}"
echo '  ███╗   ██╗██╗██╗  ██╗ ██████╗ ███████╗'
echo '  ████╗  ██║██║╚██╗██╔╝██╔═══██╗██╔════╝'
echo '  ██╔██╗ ██║██║ ╚███╔╝ ██║   ██║███████╗'
echo '  ██║╚██╗██║██║ ██╔██╗ ██║   ██║╚════██║'
echo '  ██║ ╚████║██║██╔╝ ██╗╚██████╔╝███████║'
echo '  ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝'
echo -e "${NC}"
echo -e "  ${MAG}CachyOS → NixOS  │  WiFi kexec installer  │  watch-at-console${NC}"
blank; hr; blank

[[ $EUID -eq 0 ]] && die "Do not run as root. Run as your normal user (the script uses sudo when needed)."

warn "STAGE 1 builds a NixOS installer image and kexecs into it."
warn "After kexec, CachyOS is gone from RAM and you finish at the console."
warn "Nothing is erased until you run 'install-nixos' in STAGE 2."
blank

# ═══════════════════════════════════════════════════════════════════════════════
# 1 — Dependencies (nix + flakes)
# ═══════════════════════════════════════════════════════════════════════════════
hr; info "1/6  Dependencies"; hr
if ! command -v nix &>/dev/null; then
    info "Installing nix via pacman…"
    sudo pacman -S --noconfirm --needed nix
    sudo systemctl enable --now nix-daemon.service
    getent group nix-users &>/dev/null || sudo groupadd nix-users
    sudo usermod -aG nix-users "$USER"
    warn "Added $USER to nix-users — if the build can't reach the daemon, log out/in and re-run."
else
    ok "nix present"
fi

NIX_USER_CONF="$HOME/.config/nix/nix.conf"
mkdir -p "$(dirname "$NIX_USER_CONF")"
grep -q "experimental-features" "$NIX_USER_CONF" 2>/dev/null \
    || echo 'experimental-features = nix-command flakes' >> "$NIX_USER_CONF"
sudo grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null \
    || { echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf >/dev/null
         sudo systemctl restart nix-daemon.service 2>/dev/null || true; }
ok "Flakes enabled"

# ═══════════════════════════════════════════════════════════════════════════════
# 2 — Choices
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "2/6  Configuration"; hr

blank; info "Available disks:"; lsblk -d -o NAME,SIZE,MODEL | grep -v loop; blank
warn "The disk you pick will be COMPLETELY erased in stage 2."
ask DISK_DEVICE "Target disk (e.g. sda, nvme0n1)"
DISK_DEVICE="/dev/${DISK_DEVICE#/dev/}"
[[ -b "$DISK_DEVICE" ]] || die "$DISK_DEVICE is not a block device."
ok "Target disk: $DISK_DEVICE"

choose FS_RAW "Filesystem" \
    "btrfs  — subvolumes for /, /home, /nix, /var/log, /swap  [recommended]" \
    "ext4   — simple single-partition root"
case "$FS_RAW" in btrfs*) FS="btrfs" ;; *) FS="ext4" ;; esac

LUKS=false
if ask_yn "Enable LUKS full-disk encryption?" "Y/n"; then
    LUKS=true
    ok "Encryption: LUKS (you'll type the passphrase at the console during install)"
else
    ok "Encryption: none"
fi

choose DE_RAW "Desktop environment" \
    "KDE Plasma 6  — feature-rich" \
    "GNOME         — clean, Wayland-first" \
    "None          — headless / server"
case "$DE_RAW" in KDE*) DE="kde" ;; GNOME*) DE="gnome" ;; *) DE="none" ;; esac

DISPLAY_SERVER="wayland"
if [[ "$DE" != "none" ]]; then
    choose DS_RAW "Display protocol" "Wayland [recommended]" "X11 (legacy)"
    case "$DS_RAW" in X11*) DISPLAY_SERVER="x11" ;; *) DISPLAY_SERVER="wayland" ;; esac
fi

choose ED_RAW "Default editor" "vim" "neovim" "emacs" "nano"
case "$ED_RAW" in
    vim*)    EDITOR_PKG="vim";    EDITOR_VAR="vim"   ;;
    neovim*) EDITOR_PKG="neovim"; EDITOR_VAR="nvim"  ;;
    emacs*)  EDITOR_PKG="emacs";  EDITOR_VAR="emacs" ;;
    nano*)   EDITOR_PKG="nano";   EDITOR_VAR="nano"  ;;
esac

blank
ask HOSTNAME   "Hostname"            "nixos"
ask USERNAME   "Primary username"    "$(whoami)"
ask TIMEZONE   "Timezone"            "America/New_York"
ask LOCALE     "Default locale"      "en_US.UTF-8"
ask STATE_VER  "NixOS state version" "25.05"

blank
info "Set a password for user '${USERNAME}' (used for console/GUI login and sudo)."
ask_password USER_PW "Login password for ${USERNAME}"
if command -v openssl &>/dev/null; then
    USER_PW_HASH="$(openssl passwd -6 "$USER_PW")"
else
    die "openssl not found — needed to hash the password. Install it: sudo pacman -S openssl"
fi

# Optional SSH key — handy as a fallback to reach the installer/system over WiFi
blank
SSH_PUBKEY=""
if ask_yn "Add an SSH public key (lets you SSH into the installer & final system)?" "Y/n"; then
    for f in "$HOME"/.ssh/*.pub; do [[ -f "$f" ]] && echo "  Found: $f"; done
    if ask_yn "Generate a new ed25519 key?" "Y/n"; then
        KEYFILE="$HOME/.ssh/id_ed25519_nixos"
        [[ -f "$KEYFILE" ]] || ssh-keygen -t ed25519 -C "nixos" -f "$KEYFILE" -N ""
        SSH_PUBKEY="$(cat "${KEYFILE}.pub")"
        ok "Using ${KEYFILE}.pub"
    else
        ask SSH_PUBKEY_FILE "Path to existing .pub" "$HOME/.ssh/id_ed25519.pub"
        [[ -f "$SSH_PUBKEY_FILE" ]] || die "Not found: $SSH_PUBKEY_FILE"
        SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
    fi
fi

# WiFi — required (the whole reason for the custom image)
blank; info "WiFi credentials — baked into the installer image so it auto-connects."
warn "The image will contain your WiFi password in plaintext. Keep it local; don't commit it."
ask WIFI_SSID "WiFi SSID"
ask_password WIFI_PSK "WiFi passphrase"
WIFI_HIDDEN=false
ask_yn "Hidden network?" "y/N" && WIFI_HIDDEN=true || true

# ═══════════════════════════════════════════════════════════════════════════════
# 3 — Generate files
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "3/6  Generating Nix configuration"; hr
WORKDIR="$HOME/nixos-config"
mkdir -p "$WORKDIR"; cd "$WORKDIR"

# ── disk-config.nix (disko) ──────────────────────────────────────────────────
DISK_LABEL="${FS}$([ "$LUKS" = true ] && echo ' + LUKS' || true)"
BTRFS_SUBVOLS='subvolumes = {
              "@root" = { mountpoint = "/";        mountOptions = [ "compress=zstd" "noatime" ]; };
              "@home" = { mountpoint = "/home";    mountOptions = [ "compress=zstd" "noatime" ]; };
              "@nix"  = { mountpoint = "/nix";     mountOptions = [ "compress=zstd" "noatime" ]; };
              "@log"  = { mountpoint = "/var/log"; mountOptions = [ "compress=zstd" "noatime" ]; };
            };'

{
echo '# disk-config.nix — generated by install.sh'
echo "# Layout: ${DISK_LABEL}"
echo '{ ... }:'
echo '{'
echo '  disko.devices.disk.main = {'
echo '    type = "disk";'
echo "    device = \"${DISK_DEVICE}\";"
echo '    content = {'
echo '      type = "gpt";'
echo '      partitions = {'
echo '        ESP = {'
echo '          size = "512M";'
echo '          type = "EF00";'
echo '          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; };'
echo '        };'
if [[ "$LUKS" == "true" ]]; then
echo '        luks = {'
echo '          size = "100%";'
echo '          content = {'
echo '            type = "luks";'
echo '            name = "cryptroot";'
echo '            settings.allowDiscards = true;'
if [[ "$FS" == "btrfs" ]]; then
echo '            content = {'
echo '              type = "btrfs";'
echo '              extraArgs = [ "-f" "-L" "nixos" ];'
echo "              ${BTRFS_SUBVOLS}"
echo '            };'
else
echo '            content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };'
fi
echo '          };'
echo '        };'
else
echo '        root = {'
echo '          size = "100%";'
if [[ "$FS" == "btrfs" ]]; then
echo '          content = {'
echo '            type = "btrfs";'
echo '            extraArgs = [ "-f" "-L" "nixos" ];'
echo "            ${BTRFS_SUBVOLS}"
echo '          };'
else
echo '          content = { type = "filesystem"; format = "ext4"; mountpoint = "/"; };'
fi
echo '        };'
fi
echo '      };'
echo '    };'
echo '  };'
echo '}'
} > disk-config.nix
ok "disk-config.nix ($DISK_LABEL)"

# ── desktop snippet ──────────────────────────────────────────────────────────
if   [[ "$DE" == "kde" ]]; then
    DE_NIX='  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;'
    [[ "$DISPLAY_SERVER" == "wayland" ]] && DE_NIX+='
  services.displayManager.sddm.wayland.enable = true;'
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'
elif [[ "$DE" == "gnome" ]]; then
    DE_NIX='  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;'
    [[ "$DISPLAY_SERVER" == "x11" ]] && DE_NIX+='
  services.xserver.enable = true;'
    USER_GROUPS='[ "wheel" "networkmanager" "audio" "video" ]'
else
    DE_NIX='  # headless'
    USER_GROUPS='[ "wheel" "networkmanager" ]'
fi

if [[ "$DE" != "none" ]]; then
    FONT_BLOCK='  fonts.packages = with pkgs; [ noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji liberation_ttf fira-code ];'
else
    FONT_BLOCK='  # no fonts (headless)'
fi

ROOT_KEYS=""; USER_KEYS=""
if [[ -n "$SSH_PUBKEY" ]]; then
    ROOT_KEYS="  users.users.root.openssh.authorizedKeys.keys = [ \"${SSH_PUBKEY}\" ];"
    USER_KEYS="    openssh.authorizedKeys.keys = [ \"${SSH_PUBKEY}\" ];"
fi

# ── configuration.nix ────────────────────────────────────────────────────────
cat > configuration.nix <<NIXEOF
# configuration.nix — generated by install.sh
{ config, pkgs, lib, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "${HOSTNAME}";
  networking.networkmanager.enable = true;

  time.timeZone = "${TIMEZONE}";
  i18n.defaultLocale = "${LOCALE}";

${DE_NIX}

  services.openssh = { enable = true; settings.PermitRootLogin = "prohibit-password"; };
${ROOT_KEYS}

  users.users.${USERNAME} = {
    isNormalUser = true;
    extraGroups = ${USER_GROUPS};
    hashedPassword = "${USER_PW_HASH}";
${USER_KEYS}
  };
  security.sudo.wheelNeedsPassword = true;

  environment.systemPackages = with pkgs; [ ${EDITOR_PKG} git curl wget htop ];
  environment.variables.EDITOR = "${EDITOR_VAR}";
${FONT_BLOCK}

  system.stateVersion = "${STATE_VER}";
}
NIXEOF
ok "configuration.nix"

# ── wifi.psk (raw iwd profile — no nix escaping needed) ───────────────────────
{
echo '[Security]'
echo "Passphrase=${WIFI_PSK}"
echo
echo '[Settings]'
echo 'AutoConnect=true'
[[ "$WIFI_HIDDEN" == "true" ]] && echo 'Hidden=true'
} > wifi.psk
chmod 600 wifi.psk

# nix-escape the SSID (it ends up in a nix string)
SSID_NIX="${WIFI_SSID//\\/\\\\}"; SSID_NIX="${SSID_NIX//\"/\\\"}"

# ── kexec-wifi.nix (the installer image) ─────────────────────────────────────
cat > kexec-wifi.nix <<NIXEOF
# kexec-wifi.nix — the RAM installer: WiFi + baked-in config + install-nixos
{ pkgs, lib, ... }:
let
  ssid = "${SSID_NIX}";
in {
  # Firmware so common WiFi cards (Intel/Atheros/etc.) work in the installer
  hardware.enableRedistributableFirmware = true;

  # WiFi via iwd; iwd handles association + DHCP itself
  networking.wireless.iwd = {
    enable = true;
    settings.General.EnableNetworkConfiguration = true;
  };
  # Keep systemd-networkd from fighting iwd over the wireless link
  systemd.network.networks."90-wlan-unmanaged" = {
    matchConfig.Name = "wl*";
    linkConfig.Unmanaged = true;
  };

  # Provision the WiFi network before services start, so it auto-connects on boot
  system.activationScripts.provisionWifi.text = ''
    install -d -m700 /var/lib/iwd
    cp \${./wifi.psk} "/var/lib/iwd/\${ssid}.psk"
    chmod 600 "/var/lib/iwd/\${ssid}.psk"
  '';

  # Bake the target configuration into the installer (read-only, in /etc)
  environment.etc."nixos-target/flake.nix".source        = ./flake.nix;
  environment.etc."nixos-target/flake.lock".source       = ./flake.lock;
  environment.etc."nixos-target/configuration.nix".source = ./configuration.nix;
  environment.etc."nixos-target/disk-config.nix".source  = ./disk-config.nix;

  # The single command you run at the console in stage 2
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "install-nixos" ''
      set -euo pipefail
      echo "==> Preparing a writable copy of the config…"
      rm -rf /root/nixos-target
      cp -r /etc/nixos-target /root/nixos-target
      chmod -R u+w /root/nixos-target
      cd /root/nixos-target

      echo "==> Partitioning & formatting ${DISK_DEVICE} with disko…"
      echo "    (this ERASES the disk; LUKS will prompt for your passphrase)"
      nix --extra-experimental-features 'nix-command flakes' \\
        run github:nix-community/disko -- \\
        --mode destroy,format,mount --flake .#${HOSTNAME}

      echo "==> Installing NixOS over WiFi (downloads packages to the new disk)…"
      nixos-install --no-root-passwd --flake .#${HOSTNAME}

      echo
      echo "================================================================"
      echo "  Done. Type 'reboot' to boot into your new NixOS."
      echo "  Log in as '${USERNAME}' with the password you set."
      echo "================================================================"
    '')
  ];

  # Greet the user at the console with instructions
  users.motd = ''

    ┌──────────────────────────────────────────────────────────┐
    │  NixOS installer (RAM)  —  WiFi: ${SSID_NIX}
    │
    │  When WiFi is up (check: iwctl station list / ip a), run:
    │
    │      install-nixos
    │
    │  It will erase ${DISK_DEVICE}, install NixOS, then tell you to reboot.
    └──────────────────────────────────────────────────────────┘
  '';
}
NIXEOF
ok "kexec-wifi.nix"

# ── flake.nix (target system + installer image) ──────────────────────────────
cat > flake.nix <<NIXEOF
# flake.nix — generated by install.sh
{
  description = "NixOS — ${HOSTNAME}";
  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixos-25.05";
    disko             = { url = "github:nix-community/disko";        inputs.nixpkgs.follows = "nixpkgs"; };
    nixos-images      = { url = "github:nix-community/nixos-images"; inputs.nixpkgs.follows = "nixpkgs"; };
  };
  outputs = { self, nixpkgs, disko, nixos-images, ... }:
  let system = "x86_64-linux"; in
  {
    # The system that gets installed onto the disk
    nixosConfigurations.${HOSTNAME} = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ disko.nixosModules.disko ./disk-config.nix ./configuration.nix ];
    };

    # The WiFi-enabled RAM installer we kexec into
    packages.\${system}.kexecInstaller =
      (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-images.nixosModules.kexec-installer
          nixos-images.nixosModules.noninteractive
          ./kexec-wifi.nix
        ];
      }).config.system.build.kexecInstallerTarball;
  };
}
NIXEOF
ok "flake.nix"

info "Locking flake…"; nix flake lock
ok "flake.lock"

# ═══════════════════════════════════════════════════════════════════════════════
# 4 — Validate the target config (catches option/namespace errors early)
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "4/6  Validating target configuration"; hr
info "Evaluating the NixOS system (no build yet)…"
nix eval --raw ".#nixosConfigurations.${HOSTNAME}.config.system.build.toplevel.drvPath" >/dev/null \
    && ok "Target configuration evaluates cleanly" \
    || die "Target configuration has an error (see above)."

# ═══════════════════════════════════════════════════════════════════════════════
# 5 — Build the WiFi installer image
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "5/6  Building the WiFi installer image"; hr
info "This downloads/builds the RAM installer (5–15 min on first run)…"
nix build ".#packages.x86_64-linux.kexecInstaller" -o "$WORKDIR/result-kexec"
TARBALL="$(echo "$WORKDIR"/result-kexec/*.tar.gz)"
[[ -f "$TARBALL" ]] || die "Could not find built kexec tarball under result-kexec/"
ok "Installer image built: $TARBALL"

if [[ "$BUILD_ONLY" == "true" ]]; then
    blank; hr
    ok "BUILD-ONLY: image is ready, nothing kexec'd."
    info "When you're ready to install, re-run without --build-only, or manually:"
    echo "    sudo tar -xf '$TARBALL' -C /root"
    echo "    sudo /root/kexec/run"
    blank
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 6 — kexec into the installer
# ═══════════════════════════════════════════════════════════════════════════════
blank; hr; info "6/6  Boot into the installer (kexec)"; hr; blank
echo -e "${RED}  ┌────────────────────────────────────────────────┐${NC}"
echo -e "${RED}  │   kexec will replace CachyOS in RAM right now.  │${NC}"
echo -e "${RED}  │   Your screen may flicker/blank during kexec — │${NC}"
echo -e "${RED}  │   wait up to ~60s for the installer console.    │${NC}"
echo -e "${RED}  └────────────────────────────────────────────────┘${NC}"
blank
info "After it boots, log in as root (no password) and run:  install-nixos"
[[ -n "$SSH_PUBKEY" ]] && info "Fallback: from another device, ssh root@<installer-ip> (find IP via your router)."
blank
ask_yn "kexec into the installer now?" "y/N" || { info "Not kexec'd. Image is at $TARBALL"; exit 0; }

info "Extracting installer to /root…"
sudo tar -xf "$TARBALL" -C /root
RUN_SCRIPT="$(sudo find /root -maxdepth 3 -type f -name run -path '*kexec*' 2>/dev/null | head -1)"
[[ -z "$RUN_SCRIPT" ]] && RUN_SCRIPT="/root/kexec/run"
info "Firing kexec via $RUN_SCRIPT …"
sudo "$RUN_SCRIPT"
