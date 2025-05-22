#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Global error trap
trap 'echo "ERROR: An unexpected error occurred at line $LINENO: \"$BASH_COMMAND\""' ERR
trap 'echo -e "\n🔴 Script interrupted. Cleaning up..."; cleanup; exit 130' SIGINT SIGTERM

DEBUG=false  # Set to true to enable debug mode
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Default DOC_ROOT initialization to avoid unbound variable issues (especially during uninstall)
DOC_ROOT=${DOC_ROOT:-/var/www/html}

# Cleanup function
cleanup() {
    if [[ -f /tmp/kafka.tgz ]]; then
        rm -f /tmp/kafka.tgz
        echo "Cleaned up temporary files."
    fi
}
trap cleanup EXIT

# Logging function
log_error() {
    local msg="$1"
    echo "ERROR: $msg" >&2
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') ERROR: $msg" >> "$LOGFILE"
    fi
}

##########################################
# Helper Functions                      #
##########################################

# Detect and normalize distribution ID
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID,,}"
    else
        log_error "Cannot detect operating system. Exiting."
        exit 1
    fi
}

# Enable common repos for RHEL-based systems
enable_epel_and_powertools() {
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y epel-release || true
        dnf config-manager --set-enabled powertools epel || true
    else
        yum install -y epel-release || true
        yum-config-manager --enable epel || true
    fi
}

# Common install wrapper for retry logic
install_with_retry() {
    local cmd=("$@")
    retry_command "${cmd[@]}"
}

##########################################
# Retry logic for transient errors       #
##########################################
retry_command() {
  local retries=3 delay=5 attempt=0
  until "$@" || [[ $attempt -ge $retries ]]; do
    ((attempt++))
    echo "⚠️  Attempt $attempt failed: $*. Retrying in $delay seconds..."
    sleep "$delay"
  done
  if [[ $attempt -ge $retries ]]; then
    log_error "Command failed after $retries attempts: $*"
    return 1
  fi
}

##########################################
# Package installation with repo support#
##########################################
pkg_install() {
  local pkgs=("$@")
  if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    if ! install_with_retry apt-get install -y "${pkgs[@]}"; then
      echo "⚠️  Attempting to add missing repositories..."
      apt-get install -y software-properties-common curl gnupg lsb-release ca-certificates
      for pkg in "${pkgs[@]}"; do
        case $pkg in
          php8.*)
            add-apt-repository ppa:ondrej/php -y
            ;;
          nginx)
            add-apt-repository ppa:nginx/stable -y
            ;;
        esac
      done
      apt-get update
      install_with_retry apt-get install -y "${pkgs[@]}" || log_error "❌ Could not install ${pkgs[*]}"
    fi
  else
    if ! install_with_retry dnf install -y "${pkgs[@]}"; then
      echo "⚠️  Trying to enable required repositories..."
      enable_epel_and_powertools
      install_with_retry dnf install -y "${pkgs[@]}" || log_error "❌ Could not install ${pkgs[*]}"
    fi
  fi
}

##########################################
# PHP module definitions                 #
##########################################
declare -A PHP_MODULES=(
  [core]="php php-cli php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip"
  [sqlite]="php-sqlite3 sqlite"
)

# ASCII Art and banner (omitted here for brevity)
# … (includes Fedora in supported list)

# Detect distribution and set constants
DISTRO=$(detect_distro)
case $DISTRO in
    ubuntu|debian)
        FIREWALL="ufw" ;;
    centos|rhel|rocky|almalinux|fedora)
        FIREWALL="firewalld" ;;
    *)
        log_error "Unsupported distro: $DISTRO"
        exit 1 ;;
esac

###################################
# Best PHP Version Selection      #
###################################
best_php_version() {
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        for ver in 8.2 8.1 8.0; do
            if apt-cache show php${ver} >/dev/null 2>&1; then
                echo "$ver"
                return
            fi
        done
        echo "7.4"
    else
        echo "8.2"
    fi
}

################################
# User Input Prompts           #
################################
# (unchanged from original)

################################
# install_php with Remi logic  #
################################
install_php() {
    local version_lc="${PHP_VERSION,,}"
    echo "Installing PHP ${version_lc} and necessary modules..."
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        pkg_install "php${version_lc}" "php${version_lc}-cli" "php${version_lc}-mysql" \
                    "php${version_lc}-gd" "php${version_lc}-curl" \
                    "php${version_lc}-mbstring" "php${version_lc}-xml" "php${version_lc}-zip"
        if [[ "$DB_ENGINE" == "SQLite" ]]; then
            pkg_install ${PHP_MODULES[sqlite]}
        fi
    else
        if [[ "$DISTRO" == "rocky" ]]; then
            local rel=$(rpm -E %{rhel})
            REMI_RPM="https://rpms.remirepo.net/enterprise/remi-release-${rel}.rpm"
        elif [[ "$DISTRO" == "fedora" ]]; then
            local rel=$(rpm -E %{fedora})
            REMI_RPM="https://rpms.remirepo.net/fedora/remi-release-${rel}.rpm"
        else
            REMI_RPM="https://rpms.remirepo.net/enterprise/remi-release-8.rpm"
        fi
        if ! rpm -q remi-release >/dev/null 2>&1; then
            pkg_install "$REMI_RPM"
        fi
        dnf module reset php -y
        dnf module enable php:remi-"${version_lc}" -y
        pkg_install ${PHP_MODULES[core]}
        if [[ "$DB_ENGINE" == "SQLite" ]]; then
            pkg_install ${PHP_MODULES[sqlite]}
        fi
    fi
}

################################
# Remaining installation steps #
################################
# (all other functions unchanged)

# End of script
