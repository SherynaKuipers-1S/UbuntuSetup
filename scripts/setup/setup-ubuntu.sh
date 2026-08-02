#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# setup-ubuntu.sh
#
# Provisions a fresh Ubuntu 26.04 LTS desktop for software development.
#
# Usage:
#   sudo ./setup-ubuntu.sh
#
# This script must be run with root privileges (via sudo) because it installs
# system packages, manages apt repositories, and modifies group membership.
# Actions that should happen as the normal desktop user (e.g. GNOME settings)
# are explicitly run as that user, never as root.
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

# Optional manual override for the IntelliJ IDEA Community Edition Linux
# .tar.gz download URL. Leave empty to have the script look up the current
# official release automatically via the JetBrains releases API. Only set
# this if the automatic lookup fails or you need to pin a specific build,
# e.g.:
#   INTELLIJ_DOWNLOAD_URL="https://download.jetbrains.com/idea/ideaIC-2025.2.tar.gz"
INTELLIJ_DOWNLOAD_URL=""

readonly INTELLIJ_INSTALL_DIR="/opt/intellij-idea-community"
readonly INTELLIJ_DESKTOP_FILE="/usr/share/applications/intellij-idea-community.desktop"
readonly CHROME_DEB_PATH="/tmp/google-chrome-stable_current_amd64.deb"

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
  log_error "Please run it as:  sudo ./setup-ubuntu.sh"
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

log_step "Setting up Ubuntu 26.04 LTS for development"
log_info "Target desktop user: ${CURRENT_USER} (uid ${CURRENT_USER_UID})"

# ------------------------------------------------------------------------------
# 1. Update Ubuntu
# ------------------------------------------------------------------------------

log_step "Updating package lists and upgrading installed packages"
apt update
apt upgrade -y

# ------------------------------------------------------------------------------
# 2. Install useful development tools
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
# 4. Install Google Chrome
# ------------------------------------------------------------------------------

log_step "Installing Google Chrome"

if command -v google-chrome >/dev/null 2>&1; then
  log_info "Google Chrome is already installed, skipping."
else
  log_info "Downloading the official Google Chrome .deb package..."
  curl -fsSL "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" -o "${CHROME_DEB_PATH}"

  apt-get install -y "${CHROME_DEB_PATH}"
  rm -f "${CHROME_DEB_PATH}"
  log_success "Google Chrome installed"
fi

# ------------------------------------------------------------------------------
# 5. Install IntelliJ IDEA Community Edition (standalone tar.gz)
# ------------------------------------------------------------------------------

log_step "Installing IntelliJ IDEA Community Edition"

if [[ -x "${INTELLIJ_INSTALL_DIR}/bin/idea.sh" ]]; then
  log_info "IntelliJ IDEA Community Edition is already installed at ${INTELLIJ_INSTALL_DIR}, skipping."
else
  if [[ -n "${INTELLIJ_DOWNLOAD_URL}" ]]; then
    log_info "Using manually configured INTELLIJ_DOWNLOAD_URL."
  else
    log_info "Looking up the current IntelliJ IDEA Community Edition release from JetBrains..."
    JETBRAINS_API_URL="https://data.services.jetbrains.com/products/releases?code=IIC&latest=true&type=release"

    JETBRAINS_RESPONSE="$(curl -fsSL "${JETBRAINS_API_URL}" || true)"

    if [[ -n "${JETBRAINS_RESPONSE}" ]]; then
      INTELLIJ_DOWNLOAD_URL="$(printf '%s' "${JETBRAINS_RESPONSE}" | jq -r '.IIC[0].downloads.linux.link // empty')"
    fi

    if [[ -z "${INTELLIJ_DOWNLOAD_URL}" ]]; then
      log_error "Could not automatically determine the current IntelliJ IDEA Community Edition"
      log_error "download URL from the JetBrains releases API (${JETBRAINS_API_URL})."
      log_error ""
      log_error "To proceed, edit this script and set INTELLIJ_DOWNLOAD_URL near the top to the"
      log_error "current official Linux .tar.gz URL from https://www.jetbrains.com/idea/download/#section=linux"
      log_error "(right-click the 'Download' button for the Community Edition and copy the link),"
      log_error "then re-run this script. No changes have been made to any IntelliJ installation."
      exit 1
    fi

    log_info "Resolved download URL: ${INTELLIJ_DOWNLOAD_URL}"
  fi

  INTELLIJ_ARCHIVE="/tmp/intellij-idea-community.tar.gz"
  log_info "Downloading IntelliJ IDEA Community Edition..."
  curl -fsSL "${INTELLIJ_DOWNLOAD_URL}" -o "${INTELLIJ_ARCHIVE}"

  mkdir -p "${INTELLIJ_INSTALL_DIR}"
  log_info "Extracting to ${INTELLIJ_INSTALL_DIR}..."
  tar -xzf "${INTELLIJ_ARCHIVE}" -C "${INTELLIJ_INSTALL_DIR}" --strip-components=1
  rm -f "${INTELLIJ_ARCHIVE}"

  log_success "IntelliJ IDEA Community Edition installed to ${INTELLIJ_INSTALL_DIR}"
fi

# Create/refresh the desktop launcher regardless, so it stays consistent.
INTELLIJ_ICON=""
for candidate in \
  "${INTELLIJ_INSTALL_DIR}/bin/idea.svg" \
  "${INTELLIJ_INSTALL_DIR}/bin/idea.png"; do
  if [[ -f "${candidate}" ]]; then
    INTELLIJ_ICON="${candidate}"
    break
  fi
done

{
  echo "[Desktop Entry]"
  echo "Version=1.0"
  echo "Type=Application"
  echo "Name=IntelliJ IDEA Community Edition"
  echo "Comment=Capable and ergonomic IDE for JVM development"
  echo "Exec=\"${INTELLIJ_INSTALL_DIR}/bin/idea.sh\" %f"
  if [[ -n "${INTELLIJ_ICON}" ]]; then
    echo "Icon=${INTELLIJ_ICON}"
  fi
  echo "Categories=Development;IDE;"
  echo "Terminal=false"
  echo "StartupWMClass=jetbrains-idea-ce"
} > "${INTELLIJ_DESKTOP_FILE}"

chmod 644 "${INTELLIJ_DESKTOP_FILE}"
log_success "Desktop launcher created at ${INTELLIJ_DESKTOP_FILE}"

# ------------------------------------------------------------------------------
# 6. Install Twingate
# ------------------------------------------------------------------------------

log_step "Installing Twingate"

if command -v twingate >/dev/null 2>&1; then
  log_info "Twingate is already installed, skipping."
else
  # The company-approved command is:
  #   curl -s https://binaries.twingate.com/client/linux/install.sh | sudo bash
  # This script already runs as root, so 'sudo' is omitted here, but the
  # installer behavior is otherwise identical.
  curl -s https://binaries.twingate.com/client/linux/install.sh | bash
  log_success "Twingate installed"
fi

# ------------------------------------------------------------------------------
# 7. Disable the Ubuntu Tiling Assistant GNOME extension
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
# 8. Verify installations
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
verify_command "Google Chrome" google-chrome --version
verify_command "Twingate" twingate version

if [[ -x "${INTELLIJ_INSTALL_DIR}/bin/idea.sh" ]]; then
  log_success "IntelliJ IDEA Community Edition: installed at ${INTELLIJ_INSTALL_DIR}"
else
  log_warn "IntelliJ IDEA Community Edition: not found at ${INTELLIJ_INSTALL_DIR}"
fi

# ------------------------------------------------------------------------------
# 9. Final instructions
# ------------------------------------------------------------------------------

log_step "Setup complete"

cat <<EOF

A few things you still need to do:

  1. Log out and back in (or reboot) so that '${CURRENT_USER}' can use
     Docker without sudo (group membership changes require a new session).

  2. Configure your Git identity:
       git config --global user.name "Your Name"
       git config --global user.email "your-company-email@example.com"

  3. Finish connecting Twingate:
       sudo twingate setup
     Then start the Twingate desktop client using the company-approved
     command for your environment (not assumed by this script).

  4. If required, install Outlook and Teams as Progressive Web Apps
     through Google Chrome (chrome://apps -> "Install as app" from the
     respective web app).

EOF
