#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# setup-ubuntu-personal.sh
#
# Provisions a fresh Ubuntu 26.04 LTS desktop for personal development use.
#
# Usage:
#   sudo ./setup-ubuntu-personal.sh
#
# This script must be run with root privileges (via sudo) because it installs
# system packages, manages apt repositories, and modifies group membership.
# Actions that should happen as the normal desktop user (e.g. GNOME settings)
# are explicitly run as that user, never as root.
#
# Differences from the work setup (setup-ubuntu.sh):
#   - Visual Studio Code instead of IntelliJ IDEA
#   - Firefox instead of Google Chrome
#   - Python 3 development tooling included
#   - No Twingate (not needed for personal use)
# ==============================================================================

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------

readonly C_RESET='\033[0m'
readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'

log_step()    { printf "\n${C_BLUE}==>${C_RESET} %s\n" "$1"; }
log_info()    { printf "    %s\n" "$1"; }
log_success() { printf "    ${C_GREEN}[OK]${C_RESET} %s\n" "$1"; }
log_warn()    { printf "    ${C_YELLOW}[WARN]${C_RESET} %s\n" "$1"; }
log_error()   { printf "    ${C_RED}[ERROR]${C_RESET} %s\n" "$1" >&2; }

trap 'log_error "Script failed at line ${LINENO} while running: ${BASH_COMMAND}"' ERR

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run with administrator privileges."
  log_error "Please run it as:  sudo ./setup-ubuntu-personal.sh"
  exit 1
fi

# Identify the real desktop user, even though the script itself runs as root.
CURRENT_USER="${SUDO_USER:-$USER}"

if [[ -z "${CURRENT_USER}" || "${CURRENT_USER}" == "root" ]]; then
  log_error "Could not determine the normal desktop user (got '${CURRENT_USER}')."
  log_error "Run this script with 'sudo' from your normal user account, not as root directly."
  exit 1
fi

CURRENT_USER_HOME="$(getent passwd "${CURRENT_USER}" | cut -d: -f6)"
CURRENT_USER_UID="$(id -u "${CURRENT_USER}")"

if [[ -z "${CURRENT_USER_HOME}" ]]; then
  log_error "Could not resolve a home directory for user '${CURRENT_USER}'."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log_step "Setting up Ubuntu 26.04 LTS for personal development use"
log_info "Target desktop user: ${CURRENT_USER} (uid ${CURRENT_USER_UID})"

# ------------------------------------------------------------------------------
# 1. Update Ubuntu
# ------------------------------------------------------------------------------

log_step "Updating package lists and upgrading installed packages"
apt update
apt upgrade -y

# ------------------------------------------------------------------------------
# 2. Install useful development tools (including Python)
# ------------------------------------------------------------------------------

log_step "Installing core development tools"

DEV_PACKAGES=(
  git
  curl
  wget
  ca-certificates
  gnupg
  lsb-release
  build-essential
  unzip
  zip
  jq
  tree
  vim
  nano
  openssh-client
  software-properties-common
  python3
  python3-pip
  python3-venv
  python3-dev
)

apt-get install -y --no-install-recommends "${DEV_PACKAGES[@]}"
log_success "Development tools installed"

# ------------------------------------------------------------------------------
# 3. Install Docker Engine (official Docker apt repository)
# ------------------------------------------------------------------------------

log_step "Installing Docker Engine"

if command -v docker >/dev/null 2>&1 && dpkg -s docker-ce >/dev/null 2>&1; then
  log_info "Docker Engine is already installed, skipping package installation."
else
  # Determine the Ubuntu codename (e.g. "noble", "resolute") from the OS itself
  # rather than hardcoding it, so this keeps working across LTS releases.
  # shellcheck disable=SC1091
  source /etc/os-release
  UBUNTU_CODENAME="${VERSION_CODENAME:-}"

  if [[ -z "${UBUNTU_CODENAME}" ]]; then
    log_error "Could not determine the Ubuntu codename from /etc/os-release."
    exit 1
  fi

  log_info "Detected Ubuntu codename: ${UBUNTU_CODENAME}"

  DOCKER_REPO_CHECK_URL="https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/InRelease"
  log_info "Checking whether Docker publishes a repository for '${UBUNTU_CODENAME}'..."

  if ! curl -fsS -o /dev/null "${DOCKER_REPO_CHECK_URL}"; then
    log_error "Docker does not currently provide an apt repository for Ubuntu '${UBUNTU_CODENAME}'."
    log_error "Checked: ${DOCKER_REPO_CHECK_URL}"
    log_error "This is expected shortly after a new Ubuntu release if Docker has not yet"
    log_error "published packages for it. Refer to https://docs.docker.com/engine/install/ubuntu/"
    log_error "for the current list of supported releases, then re-run this script once"
    log_error "Docker adds support for '${UBUNTU_CODENAME}'."
    exit 1
  fi

  log_info "Docker repository is available for '${UBUNTU_CODENAME}'."

  # Remove any legacy/older Docker-related packages that conflict with docker-ce.
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y "${pkg}" >/dev/null 2>&1 || true
  done

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  DOCKER_ARCH="$(dpkg --print-architecture)"
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable
EOF

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  log_success "Docker Engine installed"
fi

systemctl enable docker >/dev/null
systemctl start docker
log_success "Docker service enabled and started"

if ! getent group docker >/dev/null; then
  groupadd docker
fi

usermod -aG docker "${CURRENT_USER}"
log_success "Added '${CURRENT_USER}' to the 'docker' group (takes effect after logging back in)"

# ------------------------------------------------------------------------------
# 4. Install Firefox (official Mozilla apt repository)
# ------------------------------------------------------------------------------

log_step "Installing Firefox"

if command -v firefox >/dev/null 2>&1 && dpkg -s firefox >/dev/null 2>&1; then
  log_info "Firefox (deb package) is already installed, skipping."
else
  # Ubuntu ships Firefox as a snap by default; we instead follow Mozilla's
  # official instructions to install the real .deb package via their apt
  # repository: https://support.mozilla.org/kb/install-firefox-linux
  install -d -m 0755 /etc/apt/keyrings

  wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
    | tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null

  MOZILLA_KEY_FINGERPRINT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
  ACTUAL_FINGERPRINT="$(gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc \
    | awk '/pub/{getline; gsub(/^ +| +$/,""); print}')"

  if [[ "${ACTUAL_FINGERPRINT}" != "${MOZILLA_KEY_FINGERPRINT}" ]]; then
    log_error "Mozilla apt repository key fingerprint does not match the expected value."
    log_error "Expected: ${MOZILLA_KEY_FINGERPRINT}"
    log_error "Got:      ${ACTUAL_FINGERPRINT}"
    log_error "Refusing to proceed with an unverified signing key."
    rm -f /etc/apt/keyrings/packages.mozilla.org.asc
    exit 1
  fi

  log_info "Mozilla apt repository signing key verified."

  # shellcheck disable=SC1091
  source /etc/os-release
  UBUNTU_VERSION_ID="${VERSION_ID:-0}"

  # Mozilla publishes their repo in two formats depending on release age:
  # legacy one-line "deb" entries for Ubuntu Noble/Debian Bookworm and older,
  # and the newer deb822 .sources format for Ubuntu Resolute/Debian Trixie
  # and newer. Decide by comparing the version number rather than hardcoding
  # a codename, so this keeps working on future releases too.
  rm -f /etc/apt/sources.list.d/mozilla.list /etc/apt/sources.list.d/mozilla.sources

  if dpkg --compare-versions "${UBUNTU_VERSION_ID}" ge "26.04" 2>/dev/null; then
    cat >/etc/apt/sources.list.d/mozilla.sources <<EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
  else
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
      | tee /etc/apt/sources.list.d/mozilla.list > /dev/null
  fi

  cat >/etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

  apt-get update
  apt-get install -y firefox
  log_success "Firefox installed"
fi

# ------------------------------------------------------------------------------
# 5. Install Visual Studio Code (official Microsoft apt repository)
# ------------------------------------------------------------------------------

log_step "Installing Visual Studio Code"

if command -v code >/dev/null 2>&1; then
  log_info "Visual Studio Code is already installed, skipping."
else
  install -m 0755 -d /etc/apt/keyrings
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor > /etc/apt/keyrings/packages.microsoft.gpg
  chmod a+r /etc/apt/keyrings/packages.microsoft.gpg

  echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | tee /etc/apt/sources.list.d/vscode.list > /dev/null

  apt-get update
  apt-get install -y code
  log_success "Visual Studio Code installed"
fi

# ------------------------------------------------------------------------------
# 6. Disable the Ubuntu Tiling Assistant GNOME extension
# ------------------------------------------------------------------------------

log_step "Disabling the Tiling Assistant GNOME extension"

USER_RUNTIME_DIR="/run/user/${CURRENT_USER_UID}"
USER_DBUS_ADDRESS="unix:path=${USER_RUNTIME_DIR}/bus"

if ! command -v gnome-extensions >/dev/null 2>&1; then
  log_warn "'gnome-extensions' command not found; this may not be a GNOME desktop."
  log_warn "If applicable, run manually after logging in: gnome-extensions disable tiling-assistant@ubuntu.com"
elif [[ ! -S "${USER_RUNTIME_DIR}/bus" ]]; then
  log_warn "No active desktop session found for '${CURRENT_USER}' (no D-Bus session at ${USER_RUNTIME_DIR}/bus)."
  log_warn "Run this manually after logging in: gnome-extensions disable tiling-assistant@ubuntu.com"
else
  if sudo -u "${CURRENT_USER}" \
      DBUS_SESSION_BUS_ADDRESS="${USER_DBUS_ADDRESS}" \
      XDG_RUNTIME_DIR="${USER_RUNTIME_DIR}" \
      gnome-extensions disable tiling-assistant@ubuntu.com 2>/dev/null; then
    log_success "Tiling Assistant extension disabled"
  else
    log_warn "Could not disable the Tiling Assistant extension automatically."
    log_warn "Run this manually after logging in: gnome-extensions disable tiling-assistant@ubuntu.com"
  fi
fi

# ------------------------------------------------------------------------------
# 7. Verify installations
# ------------------------------------------------------------------------------

log_step "Verifying installed components"

verify_command() {
  local label="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    log_success "${label}: ${output%%$'\n'*}"
  else
    log_warn "${label}: not detected or version check failed"
  fi
}

verify_command "Git" git --version
verify_command "Docker" docker --version
verify_command "Docker Compose" docker compose version
verify_command "Python 3" python3 --version
verify_command "pip" python3 -m pip --version
verify_command "Firefox" firefox --version
verify_command "Visual Studio Code" code --version

# ------------------------------------------------------------------------------
# 8. Final instructions
# ------------------------------------------------------------------------------

log_step "Setup complete"

cat <<EOF

A few things you still need to do:

  1. Log out and back in (or reboot) so that '${CURRENT_USER}' can use
     Docker without sudo (group membership changes require a new session).

  2. Configure your Git identity:
       git config --global user.name "Your Name"
       git config --global user.email "your-personal-email@example.com"

EOF
