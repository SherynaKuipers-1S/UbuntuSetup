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
  log_error "Please run it as: sudo ./setup-ubuntu.sh"
  exit 1
fi

CURRENT_USER="${SUDO_USER:-$USER}"

if [[ -z "${CURRENT_USER}" || "${CURRENT_USER}" == "root" ]]; then
  log_error "Could not determine the normal desktop user."
  log_error "Run this script with sudo from your normal user account."
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
log_info "Target desktop user: ${CURRENT_USER} (UID ${CURRENT_USER_UID})"

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
# 3. Install Docker Engine
# ------------------------------------------------------------------------------

log_step "Installing Docker Engine"

if command -v docker >/dev/null 2>&1 && \
   dpkg -s docker-ce >/dev/null 2>&1; then

  log_info "Docker Engine is already installed."
else

  source /etc/os-release

  UBUNTU_CODENAME="${VERSION_CODENAME:-}"

  if [[ -z "${UBUNTU_CODENAME}" ]]; then
    log_error "Could not determine the Ubuntu codename."
    exit 1
  fi

  log_info "Detected Ubuntu codename: ${UBUNTU_CODENAME}"

  DOCKER_REPO_CHECK_URL="https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/InRelease"

  log_info "Checking Docker repository availability..."

  if ! curl -fsS -o /dev/null "${DOCKER_REPO_CHECK_URL}"; then
    log_error "Docker does not currently provide a repository for Ubuntu '${UBUNTU_CODENAME}'."
    log_error "Checked: ${DOCKER_REPO_CHECK_URL}"
    log_error "Check Docker's official Ubuntu installation documentation."
    exit 1
  fi

  log_success "Docker repository is available."

  for pkg in \
    docker.io \
    docker-doc \
    docker-compose \
    podman-docker \
    containerd \
    runc
  do
    apt-get remove -y "${pkg}" >/dev/null 2>&1 || true
  done

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

  chmod a+r /etc/apt/keyrings/docker.asc

  DOCKER_ARCH="$(dpkg --print-architecture)"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
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

log_success "Added '${CURRENT_USER}' to the Docker group"

# ------------------------------------------------------------------------------
# 4. Install Google Chrome
# ------------------------------------------------------------------------------

log_step "Installing Google Chrome"

readonly CHROME_DEB_PATH="/tmp/google-chrome-stable_current_amd64.deb"

if command -v google-chrome >/dev/null 2>&1; then

  log_info "Google Chrome is already installed."

else

  log_info "Downloading the official Google Chrome package..."

  curl -fsSL \
    "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
    -o "${CHROME_DEB_PATH}"

  apt-get install -y "${CHROME_DEB_PATH}"

  rm -f "${CHROME_DEB_PATH}"

  log_success "Google Chrome installed"
fi

# ------------------------------------------------------------------------------
# 5. Install Twingate
# ------------------------------------------------------------------------------

log_step "Installing Twingate"

if command -v twingate >/dev/null 2>&1; then

  log_info "Twingate is already installed."

else

  curl -s \
    https://binaries.twingate.com/client/linux/install.sh \
    | bash

  log_success "Twingate installed"
fi

log_step "Setting up Twingate"

twingate setup

log_success "Twingate setup completed"

# ------------------------------------------------------------------------------
# 6. Disable Ubuntu Tiling Assistant
# ------------------------------------------------------------------------------

log_step "Disabling the Tiling Assistant GNOME extension"

USER_RUNTIME_DIR="/run/user/${CURRENT_USER_UID}"
USER_DBUS_ADDRESS="unix:path=${USER_RUNTIME_DIR}/bus"

if ! command -v gnome-extensions >/dev/null 2>&1; then

  log_warn "The gnome-extensions command was not found."
  log_warn "Run this manually after logging in:"
  log_warn "gnome-extensions disable tiling-assistant@ubuntu.com"

elif [[ ! -S "${USER_RUNTIME_DIR}/bus" ]]; then

  log_warn "No active GNOME D-Bus session was found."
  log_warn "Run this manually after logging in:"
  log_warn "gnome-extensions disable tiling-assistant@ubuntu.com"

else

  if sudo -u "${CURRENT_USER}" \
    DBUS_SESSION_BUS_ADDRESS="${USER_DBUS_ADDRESS}" \
    XDG_RUNTIME_DIR="${USER_RUNTIME_DIR}" \
    gnome-extensions disable tiling-assistant@ubuntu.com \
    2>/dev/null
  then

    log_success "Tiling Assistant extension disabled"

  else

    log_warn "Could not disable Tiling Assistant automatically."
    log_warn "Run this manually after logging in:"
    log_warn "gnome-extensions disable tiling-assistant@ubuntu.com"

  fi
fi

# ------------------------------------------------------------------------------
# 7. Verify installed components
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

# ------------------------------------------------------------------------------
# 8. Install IntelliJ IDEA
# ------------------------------------------------------------------------------

log_step "Installing IntelliJ IDEA"

INTELLIJ_ARCHIVE="/tmp/intellij-idea.tar.gz"

INTELLIJ_DOWNLOAD_URL="https://download.jetbrains.com/idea/idea-2026.2.0.1.tar.gz"

log_info "Downloading IntelliJ IDEA..."

wget \
  -O "${INTELLIJ_ARCHIVE}" \
  "${INTELLIJ_DOWNLOAD_URL}"

log_info "Checking the downloaded archive..."

if ! tar -tzf "${INTELLIJ_ARCHIVE}" >/dev/null 2>&1; then
  log_error "The IntelliJ download is not a valid .tar.gz archive."
  rm -f "${INTELLIJ_ARCHIVE}"
  exit 1
fi

INTELLIJ_TOP_LEVEL="$(
  tar -tzf "${INTELLIJ_ARCHIVE}" \
    | head -n 1 \
    | cut -d/ -f1
)"

if [[ -z "${INTELLIJ_TOP_LEVEL}" ]]; then
  log_error "Could not determine the IntelliJ directory in the archive."
  rm -f "${INTELLIJ_ARCHIVE}"
  exit 1
fi

INTELLIJ_INSTALL_DIR="/opt/${INTELLIJ_TOP_LEVEL}"

if [[ -e "${INTELLIJ_INSTALL_DIR}" ]]; then
  log_warn "An IntelliJ directory already exists:"
  log_warn "${INTELLIJ_INSTALL_DIR}"
  log_warn "Skipping extraction to avoid overwriting an existing installation."

else
  log_info "Extracting IntelliJ to /opt..."

  tar \
    -xzf "${INTELLIJ_ARCHIVE}" \
    -C /opt

  if [[ -x "${INTELLIJ_INSTALL_DIR}/bin/idea.sh" ]]; then
    log_success "IntelliJ IDEA installed successfully"

    log_info "Installation directory:"
    log_info "${INTELLIJ_INSTALL_DIR}"

    log_info "Start IntelliJ with:"
    log_info "${INTELLIJ_INSTALL_DIR}/bin/idea.sh"

  else
    log_error "IntelliJ was extracted, but bin/idea.sh was not found."
    rm -f "${INTELLIJ_ARCHIVE}"
    exit 1
  fi
fi

rm -f "${INTELLIJ_ARCHIVE}"

# ------------------------------------------------------------------------------
# 9. Final instructions
# ------------------------------------------------------------------------------

log_step "Setup complete"

cat <<EOF

A few things you still need to do:

1. Log out and log back in, or reboot.

   This is required before '${CURRENT_USER}' can use Docker without sudo.

2. Configure your Git identity:

   git config --global user.name "Your Name"

   git config --global user.email "your-company-email@example.com"

3. Finish connecting Twingate:

   sudo twingate setup

   Then start the Twingate desktop client using the company-approved
   command for your environment.

4. If required, install Outlook and Teams as Progressive Web Apps
   through Google Chrome.

5. IntelliJ IDEA Ultimate was installed last.

   If you skipped it, download the correct .tar.gz archive from:

   https://www.jetbrains.com/idea/download/

   Extract it into a clean directory under /opt and run:

   /opt/<IntelliJ-directory>/bin/idea.sh

EOF
