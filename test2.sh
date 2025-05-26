#!/bin/bash

# Check for Bash version (associative arrays require Bash 4.0+)
if [[ -z "${BASH_VERSINFO[0]}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: This script requires Bash version 4.0 or higher." >&2
  echo "You are using Bash version: ${BASH_VERSION:-$(bash --version | head -n1)}" >&2
  exit 1
fi

set -euo pipefail
IFS=$'\n\t'


##############################
# Global Settings & Traps
##############################

# Debugging & Verbose flags
DEBUG=false
VERBOSE=false
if [[ "$DEBUG" == true ]]; then
    set -x
fi

# Global log file variable (will be set later)
LOGFILE=""

# Global trap for unexpected errors and job interruption.
trap 'echo "ERROR: An unexpected error occurred at line ${LINENO}: \"${BASH_COMMAND}\""' ERR
trap 'echo -e "\n🔴 Script interrupted. Cleaning up..."; cleanup; exit 130' SIGINT SIGTERM

# Cleanup function – remove temporary files, etc.
cleanup() {
    if [[ -f /tmp/kafka.tgz ]]; then
        rm -f /tmp/kafka.tgz
        log_info "Cleaned up temporary files."
    fi
}
trap cleanup EXIT

##############################
# Logging Functions
##############################
log_error() {
    # Clear progress bar line before printing error to avoid overlap
    printf "\r\033[K"
    local msg="$1"
    local func="${FUNCNAME[1]:-main}"
    local line="${BASH_LINENO[0]:-unknown}"
    echo "ERROR in ${func} at line ${line}: $msg" >&2
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') ERROR in ${func} (line ${line}): $msg" >> "$LOGFILE"
    fi
}

log_warn() {
    # Clear progress bar line before printing warning to avoid overlap
    printf "\r\033[K"
    local msg="$1"
    local func="${FUNCNAME[1]:-main}"
    local line="${BASH_LINENO[0]:-unknown}"
    echo "WARN in ${func} at line ${line}: $msg" >&2 # Output to stderr for visibility
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') WARN in ${func} (line ${line}): $msg" >> "$LOGFILE"
    fi
}

log_info() {
    local msg="$1"
    # Clear progress bar line before printing info to avoid overlap if VERBOSE is true
    # Otherwise, info only goes to log file, progress bar stays on its line.
    [[ "${VERBOSE}" == true ]] && printf "\r\033[K"
    if [[ "${VERBOSE}" == true ]]; then
        echo "INFO: $msg"
    fi
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') INFO: $msg" >> "$LOGFILE"
    fi
}

# Progress Bar Function
# Arguments:
#   $1: current_step
#   $2: total_steps
#   $3: message (optional)
display_progress() {
    local current_step=$1
    local total_steps=$2
    local message="${3:-Progress}"
    local progress_bar_width=50
    local color_red='\033[0;31m'
    local color_nc='\033[0m' # No Color

    if [[ "$total_steps" -le 0 ]]; then
        printf "\r${color_red}%s: [No steps defined]${color_nc}\033[K" "$message"
        # If current_step implies completion (e.g. current_step >= total_steps, though total_steps is 0 here)
        # we might want a newline, but it's ambiguous with 0 total_steps.
        # For now, just print the message and clear the line.
        echo # Add a newline so subsequent output is clean.
        return
    fi

    # Cap current_step and calculate percentage
    if [[ "$current_step" -gt "$total_steps" ]]; then current_step="$total_steps"; fi
    local percentage=$((current_step * 100 / total_steps))
    if [[ "$percentage" -gt 100 ]]; then percentage=100; fi

    local filled_width=$((current_step * progress_bar_width / total_steps))
    if [[ "$filled_width" -gt "$progress_bar_width" ]]; then filled_width="$progress_bar_width"; fi
    local empty_width=$((progress_bar_width - filled_width))

    local bar=""
    for ((i=0; i<filled_width; i++)); do bar="${bar}#"; done
    for ((i=0; i<empty_width; i++)); do bar="${bar}-"; done

    printf "\r${color_red}%s: [%s] %d%%${color_nc}\033[K" "$message" "$bar" "$percentage"

    if [[ "$current_step" -eq "$total_steps" ]]; then
        echo # Newline when complete
    fi
}

##############################
# Helper Functions
##############################

# Detect Linux distribution using /etc/os-release
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID,,}"
    else
        log_error "/etc/os-release not found. Defaulting to ubuntu."
        echo "ubuntu"
    fi
}

# Allow pre-setting DISTRO from the environment; otherwise, auto-detect.
init_distro() {
    local detected=""
    if [[ -z "${DISTRO-}" ]]; then
        detected=$(detect_distro)
    else
        detected=$(echo "${DISTRO}" | tr '[:upper:]' '[:lower:]')
    fi

    case "$detected" in
        ubuntu|debian|centos|rocky|almalinux|fedora|rhel|linuxmint)
            DISTRO="$detected"
            ;;
        *)
            log_error "Unsupported Linux distribution detected: $detected"
            exit 1
            ;;
    esac
    echo "$DISTRO"
}

# Helper to get PHP version without dot (e.g., 8.1 -> 81)
get_php_version_no_dot() {
    echo "${1//./}"
}


# Detect the package manager
get_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt-get"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        log_error "No supported package manager found."
        exit 1
    fi
}

# Helper to identify Debian-based distros.
is_debian() {
    [[ "$DISTRO" =~ ^(ubuntu|debian|linuxmint)$ ]]
}

# Helper to identify RPM-based distros.
is_rpm() {
    [[ "$DISTRO" =~ ^(centos|rhel|rocky|almalinux|fedora)$ ]]
}

# Prepare DocumentRoot directory and set proper ownership/permissions.
prepare_docroot() {
    local doc_root="${DOC_ROOT:-/var/www/html}"
    log_info "Preparing DocumentRoot at ${doc_root}..."
    if [[ ! -d "$doc_root" ]]; then
        log_info "Creating directory: $doc_root"
        sudo mkdir -p "$doc_root"
    fi
    local owner=""
    if is_debian; then
        owner="www-data"
    else
        owner="apache"
    fi
    sudo chown -R "$owner":"$owner" "$doc_root"
    sudo chmod -R 755 "$doc_root"
    if command -v restorecon >/dev/null 2>&1; then
        sudo restorecon -Rv "$doc_root"
    fi
}

##############################
# Package Management Functions
##############################

pkg_install() {
    local pkgs=("$@")
    log_info "Installing packages: ${pkgs[*]} on distro: ${DISTRO}"
    local pkg_manager
    pkg_manager=$(get_package_manager)

    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            if ! sudo apt-get install -y "${pkgs[@]}"; then
                log_error "Installation failed for packages: ${pkgs[*]} via apt-get."
                exit 2
            fi
            ;;
        centos|rhel|rocky|almalinux)
            if ! sudo dnf install -y "${pkgs[@]}"; then
                log_error "Installation failed for packages: ${pkgs[*]} via dnf."
                exit 2
            fi
            ;;
        fedora)
            if ! sudo dnf install -y "${pkgs[@]}"; then
                log_error "Installation failed for packages: ${pkgs[*]} via dnf on Fedora."
                exit 2
            fi
            ;;
        *)
            log_error "Using fallback installation method on unknown distro: ${DISTRO}"
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get install -y "${pkgs[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "${pkgs[@]}"
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y "${pkgs[@]}"
            else
                log_error "Failed to install packages: ${pkgs[*]}. No known package manager available."
                exit 2
            fi
            ;;
    esac
}

pkg_update() {
    log_info "Updating system on $DISTRO..."
    if is_debian; then
        sudo apt-get update && sudo apt-get upgrade -y || { log_error "Update/upgrade failed on Debian-based system."; exit 2; }
    else
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf update -y || { log_error "Update failed on $DISTRO."; exit 2; }
        else
            sudo yum update -y || { log_error "Update failed on $DISTRO."; exit 2; }
        fi
    fi
}

pkg_remove() {
    if is_debian; then
        sudo apt-get purge -y "$@"
    else
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf remove -y "$@"
        else
            sudo yum remove -y "$@"
        fi
    fi
}

remove_if_installed() {
    local pkg="$1"
    if is_debian; then
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            log_info "Removing package: $pkg"
            pkg_remove "$pkg"
        else
            log_info "Package $pkg not installed, skipping."
        fi
    else
        if rpm -q "$pkg" >/dev/null 2>&1; then
            log_info "Removing package: $pkg"
            pkg_remove "$pkg"
        else
            log_info "Package $pkg not installed, skipping."
        fi
    fi
}

##############################
# Additional Functional Modules
##############################

# Enable EPEL and related repos for RPM-based systems
enable_epel_and_powertools() {
    if command -v dnf >/dev/null 2>&1; then
        if ! rpm -q epel-release &>/dev/null; then
            log_info "Installing EPEL repository..."
            if ! sudo dnf install -y epel-release; then
                log_error "Failed to install EPEL repository. This might affect other installations."
                # Consider exiting if EPEL is critical for subsequent steps: exit 1
            fi
        fi
        if grep -q "Rocky Linux 9" /etc/os-release; then
            log_info "Enabling CodeReady Builder (CRB) repository for Rocky Linux 9..."
            if ! sudo dnf config-manager --set-enabled crb; then
                 log_warn "Failed to enable CRB repository. Some packages might not be available."
            fi
        else
            log_info "Enabling PowerTools repository (or equivalent like CRB for other RHEL clones)..."
            # Try enabling powertools, if that fails try crb (common for AlmaLinux, RHEL)
            if ! sudo dnf config-manager --set-enabled powertools && ! sudo dnf config-manager --set-enabled crb; then
                 log_warn "Failed to enable PowerTools/CRB repository. Some packages might not be available."
            fi
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! sudo yum install -y epel-release; then
            log_error "Failed to install EPEL repository via yum."
        fi
        # yum-config-manager might not be installed by default, epel-release usually enables itself.
    fi
}

# Return best PHP version available for the distro.
best_php_version() {
    local version=""
    case "$DISTRO" in
        ubuntu|debian|linuxmint)
            for ver in 8.3 8.2 8.1 8.0; do
                if apt-cache show php"${ver}" >/dev/null 2>&1; then
                    version="$ver"
                    break
                fi
            done
            echo "${version:-7.4}"
            ;;
        fedora)
            for ver in 8.3 8.2 8.1 8.0; do
                # Fedora uses Remi for PHP in this script, so check Remi modules
                if dnf module info php:remi-"${ver}" &>/dev/null; then
                    version="$ver"
                    break
                fi
            done
            echo "${version:-8.2}"
            ;;
        centos|rocky|almalinux|rhel)
            for ver in 8.3 8.2 8.1 8.0; do
                if dnf module info php:remi-"${ver}" &>/dev/null; then
                    version="$ver"
                    break
                fi
            done
            echo "${version:-7.4}"
            ;;
        *)
            echo "8.2"
            ;;
    esac
}

# PHP Installation
install_php() {
    if command -v php >/dev/null 2>&1; then
        log_info "PHP already installed at $(command -v php): $(php -v | head -n 1)"
        return 0
    fi
    PHP_VERSION=$(best_php_version)
    log_info "Installing PHP ${PHP_VERSION} and required modules..."
    if is_debian; then
        pkg_install "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" \
                    "php${PHP_VERSION}-gd" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-mbstring" \
                    "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip"
        if [[ "${DB_ENGINE:-MariaDB}" == "SQLite" ]]; then
            pkg_install "php${PHP_VERSION}-sqlite3" sqlite3 # sqlite3 is the command-line tool
        fi
    else
        # For RPM-based distros, ensure remi repositories are enabled.
        local rel=""
        if [[ "$DISTRO" =~ ^(rocky|almalinux|rhel)$ ]]; then
            rel=$(rpm -E %{rhel})
            REMI_RPM="https://rpms.remirepo.net/enterprise/remi-release-${rel}.rpm"
        elif [[ "$DISTRO" == "fedora" ]]; then
            rel=$(rpm -E %{fedora})
            REMI_RPM="https://rpms.remirepo.net/fedora/remi-release-${rel}.rpm"
        else
            REMI_RPM="https://rpms.remirepo.net/enterprise/remi-release-8.rpm"
        fi
        if ! rpm -q remi-release >/dev/null 2>&1; then
            pkg_install "$REMI_RPM"
        fi

        sudo dnf module reset php -y
        if ! sudo dnf module enable php:remi-"${PHP_VERSION}" -y; then
            log_error "Failed to enable php:remi-${PHP_VERSION} module stream"
            exit 3
        fi
        # This command installs the default profile for the enabled PHP stream,
        # which includes php-cli, php-fpm, php-common, and several extensions.
        log_info "Installing PHP packages from enabled Remi module stream..."
        if ! sudo dnf install -y @php; then # Installs packages from the enabled module stream
             log_error "Failed to install packages from enabled PHP module stream @php"
             # As an alternative, or to be more explicit:
             # pkg_install php-cli php-fpm php-common # Basic set
             # exit 3 # Or handle more gracefully
        fi

        # Install additional common PHP extensions explicitly.
        # Many of these might already be pulled in by '@php' or the default module profile.
        # Listing them ensures they are present.
        local php_extensions_rpm=("php-mysqlnd" "php-gd" "php-curl" "php-mbstring" "php-xml" "php-zip" "php-json" "php-opcache")
        if ! pkg_install "${php_extensions_rpm[@]}"; then
            log_error "Failed to install one or more PHP extensions: ${php_extensions_rpm[*]}"
            exit 3
        fi
        if [[ "${DB_ENGINE:-MariaDB}" == "SQLite" ]]; then
            pkg_install php-sqlite3 sqlite3 # sqlite3 is the command-line tool
        fi
    fi
}

install_database() {
    log_info "Installing database engine: ${DB_ENGINE}"
    if [[ "${DB_ENGINE}" == "MySQL" && ( "$DISTRO" =~ ^(centos|rhel|rocky|almalinux)$ ) ]]; then
        log_info "MySQL not available by default on $DISTRO; switching to MariaDB."
        DB_ENGINE="MariaDB"
    fi

    # Helper to fix package misconfigurations on Debian-based systems.
    fix_pkg_misconfigs() {
        log_info "Attempting to fix package misconfigurations with 'apt-get install -f' and 'dpkg --configure -a'."
        sudo apt-get install -f
        sudo dpkg --configure -a
    }

    # Debian-based wrapper for pkg_install.
    pkg_install_debian() {
        pkg_install "$@" || { 
            fix_pkg_misconfigs
            return 1
        }
    }

    case "${DB_ENGINE}" in
        "MariaDB")
            # On Linux Mint, force reinstallation of mariadb-common to fix its post-install script error
            if [[ "$DISTRO" == "linuxmint" ]]; then
                log_info "Detected Linux Mint: Reinstalling mariadb-common to work around post-install script error"
                sudo DEBIAN_FRONTEND=noninteractive apt-get update
                sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y mariadb-common || {
                    log_error "Failed to reinstall mariadb-common"
                    fix_pkg_misconfigs
                    return 1
                }
                sudo dpkg --configure -a || {
                    log_error "dpkg configuration of mariadb-common still failing"
                    fix_pkg_misconfigs
                    return 1
                }
            fi

            if is_debian; then
                pkg_install_debian mariadb-server || return 1
            else
                pkg_install mariadb-server
            fi
            sudo systemctl enable --now mariadb
            log_info "Configuring MariaDB..."
            if [[ "$DISTRO" =~ ^(rocky|almalinux|rhel)$ ]]; then
                sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF
            else
                local auth_plugin
                auth_plugin=$(sudo mysql -N -e "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" 2>/dev/null || echo '')
                if [[ "$auth_plugin" == "unix_socket" || "$auth_plugin" == "auth_socket" ]]; then
                    sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF
                else
                    if [[ -z "${CURRENT_ROOT_PASSWORD:-}" ]]; then
                        read -s -p "Enter current MariaDB root password (if any, press ENTER if none): " CURRENT_ROOT_PASSWORD
                        echo
                    fi
                    if [[ -n "$CURRENT_ROOT_PASSWORD" ]]; then
                        sudo mysql -uroot -p"${CURRENT_ROOT_PASSWORD}" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
                    else
                        sudo mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
                    fi
                fi
            fi
            ;;

        "MySQL")
            if is_debian; then
                pkg_install_debian mysql-server || return 1
            else
                pkg_install mysql-server
            fi
            sudo systemctl enable --now mysql
            sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
            ;;

        "PostgreSQL")
            if is_debian; then
                pkg_install_debian postgresql postgresql-contrib || return 1
            else
                pkg_install postgresql postgresql-contrib
            fi
            sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_PASSWORD}';"
            ;;

        "SQLite")
            log_info "SQLite is file‑based and already comes with PHP support."
            ;;

        "Percona")
            if is_debian; then
                pkg_install_debian percona-server-server || return 1
            else
                pkg_install percona-server-server
            fi
            sudo systemctl enable --now mysql
            sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
            ;;

        "MongoDB")
            if is_debian; then
                wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/mongodb.gpg >/dev/null
                echo "deb [arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu \$(lsb_release -sc)/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
                pkg_update || { fix_pkg_misconfigs; return 1; }
                pkg_install_debian mongodb-org || return 1
                sudo systemctl enable --now mongod
            elif is_rpm; then
                cat <<EOF | sudo tee /etc/yum.repos.d/mongodb-org-6.0.repo
[mongodb-org-6.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$(rpm -E %{rhel})/mongodb-org/6.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-6.0.asc
EOF
                pkg_update
                pkg_install mongodb-org
                sudo systemctl enable --now mongod
            else
                log_error "MongoDB setup not configured for distro: ${DISTRO}"
            fi
            ;;

        "OracleXE")
            log_error "Oracle XE installation requires manual steps. Please refer to Oracle documentation."
            ;;
    esac
}


# Stub function: Setup optional FTP/SFTP server.
install_ftp_sftp() {
    if [[ "${INSTALL_FTP:-false}" == true ]]; then
        pkg_install vsftpd
    fi
}

# Install caching system based on user choice.
install_cache() {
    case "${CACHE_SETUP}" in
        "Redis")
            if is_debian; then
                pkg_install redis-server
            else
                pkg_install redis
            fi
            ;;
        "Memcached")
            pkg_install memcached "php${PHP_VERSION}-memcached"
            ;;
        "Varnish")
            pkg_install varnish
            ;;
        "None")
            log_info "No caching system selected."
            ;;
    esac
}

# Install messaging queue based on user choice.
install_messaging_queue() {
    case "${MSG_QUEUE}" in
        "RabbitMQ")
            pkg_install rabbitmq-server
            ;;
        "Kafka")
            if is_debian; then
                pkg_install openjdk-11-jdk
            else
                pkg_install "$JAVA_PACKAGE"
            fi
            local KAFKA_VERSION="2.8.1"
            local KAFKA_SCALA="2.13"
            wget "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" -O /tmp/kafka.tgz
            tar -xzf /tmp/kafka.tgz -C /opt
            sudo mv /opt/kafka_${KAFKA_SCALA}-${KAFKA_VERSION} /opt/kafka
            # Create a basic user for Kafka if it doesn't exist
            if ! id kafka >/dev/null 2>&1; then
                sudo useradd --system --no-create-home --shell /bin/false kafka
            fi
            sudo chown -R kafka:kafka /opt/kafka

            # Basic Zookeeper Systemd Service
            cat <<EOF | sudo tee /etc/systemd/system/zookeeper.service
[Unit]
Description=Apache Zookeeper server
Documentation=http://zookeeper.apache.org
Requires=network.target remote-fs.target
After=network.target remote-fs.target

[Service]
Type=simple
User=kafka
Group=kafka
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
ExecStop=/opt/kafka/bin/zookeeper-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
            # Basic Kafka Systemd Service
            cat <<EOF | sudo tee /etc/systemd/system/kafka.service
[Unit]
Description=Apache Kafka Server
Documentation=http://kafka.apache.org/documentation.html
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=kafka
Group=kafka
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now zookeeper
            sudo systemctl enable --now kafka
            ;;
        "None")
            log_info "No messaging queue selected."
            ;;
    esac
}

# Install web server based on the user’s selection.
install_web_server() {
    case "${WEB_SERVER}" in
        "Nginx")
            pkg_install nginx
            ;;
        "Apache")
            if is_debian; then
                pkg_install apache2 apache2-utils
            else
                pkg_install "$APACHE_PACKAGE"
                sudo systemctl enable --now "$APACHE_PACKAGE"
            fi
            ;;
        "Caddy")
            if is_debian; then
                pkg_install debian-keyring debian-archive-keyring apt-transport-https
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo tee /etc/apt/trusted.gpg.d/caddy-stable.asc
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
                pkg_update
                pkg_install caddy
            else
                log_info "Installing Caddy on $DISTRO (RPM-based)..."
                pkg_install 'dnf-command(copr)' # Ensures dnf copr subcommand is available
                if ! sudo dnf copr enable -y '@caddy/caddy'; then
                    log_error "Failed to enable Caddy COPR repository. Caddy installation will likely fail."
                    # Consider exiting: exit 1
                fi
                pkg_install caddy
                sudo systemctl enable --now caddy
            fi
            ;;
        "Lighttpd")
            pkg_install lighttpd
            ;;
    esac
}

# Set up virtual hosts or server configuration based on web server
setup_virtual_hosts() {
    log_info "Setting up virtual hosts..."
    local php_fpm_socket_path=""
    local php_version_no_dot=""

    if [[ -n "${PHP_VERSION:-}" ]]; then # Ensure PHP_VERSION is set
        php_version_no_dot=$(get_php_version_no_dot "$PHP_VERSION")
        if is_debian; then
            php_fpm_socket_path="unix:/run/php/php${PHP_VERSION}-fpm.sock"
        elif is_rpm; then
            # Common paths for Remi PHP FPM, might need further refinement or detection
            if [[ -S "/var/opt/remi/php${php_version_no_dot}/run/php-fpm/www.sock" ]]; then
                php_fpm_socket_path="unix:/var/opt/remi/php${php_version_no_dot}/run/php-fpm/www.sock"
            elif [[ -S "/run/php-fpm/www.sock" ]]; then # If Remi configures the system-wide php-fpm
                php_fpm_socket_path="unix:/run/php-fpm/www.sock"
            else # Fallback or older Remi path
                php_fpm_socket_path="unix:/var/run/php-fpm/www.sock" # General fallback, check your Remi setup
                log_warn "Could not definitively determine Remi PHP-FPM socket path for Nginx, using fallback: ${php_fpm_socket_path}"
            fi
        else
            php_fpm_socket_path="unix:/var/run/php/php${PHP_VERSION}-fpm.sock" # Default guess
            log_warn "Unknown distro type for PHP-FPM socket path, using default: ${php_fpm_socket_path}"
        fi
    else
        log_warn "PHP_VERSION not set, cannot determine PHP-FPM socket path for Nginx."
    fi

    if [[ "${WEB_SERVER}" == "Nginx" ]]; then
        for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
            DOMAIN=$(echo "$DOMAIN" | xargs)
            mkdir -p "${DOC_ROOT}/${DOMAIN}"
            local nginx_vhost_content=""
            nginx_vhost_content=$(cat <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${DOC_ROOT}/${DOMAIN};
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
$( [[ -n "$php_fpm_socket_path" ]] && cat <<EOT_PHP
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass ${php_fpm_socket_path};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
EOT_PHP
)
    location ~ /\.ht {
        deny all;
    }
}
EOF
            if is_debian; then
                echo "$nginx_vhost_content" | sudo tee "/etc/nginx/sites-available/${DOMAIN}" > /dev/null
                sudo ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
            elif is_rpm; then
                # On RPM systems, Nginx typically loads all .conf files from /etc/nginx/conf.d/
                echo "$nginx_vhost_content" | sudo tee "/etc/nginx/conf.d/${DOMAIN}.conf" > /dev/null
            else
                log_warn "Nginx vhost setup for ${DOMAIN} might not be correct for this distribution: ${DISTRO}"
                # Fallback to Debian style as a guess
                echo "$nginx_vhost_content" | sudo tee "/etc/nginx/sites-available/${DOMAIN}" > /dev/null
                sudo ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/"
            fi
        done
        sudo systemctl reload nginx
    elif [[ "${WEB_SERVER}" == "Apache" ]]; then
        local VHOST_DIR="" APACHE_LOG_DIR="" RELOAD_CMD="" DISABLE_DEFAULT=""
        if is_debian; then
            VHOST_DIR="/etc/apache2/sites-available"
            RELOAD_CMD="sudo systemctl reload apache2"
            DISABLE_DEFAULT="sudo a2dissite 000-default"
            APACHE_LOG_DIR="/var/log/apache2"
        else
            VHOST_DIR="/etc/httpd/conf.d"
            RELOAD_CMD="sudo systemctl reload httpd"
            APACHE_LOG_DIR="/var/log/httpd"
        fi
        for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
            DOMAIN=$(echo "$DOMAIN" | xargs)
            mkdir -p "${DOC_ROOT}/${DOMAIN}"
            cat <<EOF | sudo tee "${VHOST_DIR}/${DOMAIN}.conf"
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${DOC_ROOT}/${DOMAIN}
    <Directory ${DOC_ROOT}/${DOMAIN}>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog ${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF
            if is_debian; then
                sudo a2ensite "${DOMAIN}.conf"
            fi
        done
        if is_debian; then
            sudo a2dissite 000-default
        fi
        eval "$RELOAD_CMD"
        log_info "Apache virtual hosts configured."
    fi
}

optimize_performance() {
    log_info "Optimizing system performance..."

    # PHP configuration adjustments
    local PHP_INI
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -n "$PHP_INI" && -f "$PHP_INI" ]]; then
        if [[ ! -f "${PHP_INI}.bak.lamp" ]]; then # Create backup only once by this script
             sudo cp "$PHP_INI" "${PHP_INI}.bak.lamp"
        fi
        # Use a temporary file for sed operations to avoid issues with multiple seds on the same file
        local tmp_php_ini
        tmp_php_ini=$(mktemp)
        sudo cp "$PHP_INI" "$tmp_php_ini"
        sudo sed -i 's/^expose_php = On/expose_php = Off/' "$tmp_php_ini"
        sudo sed -i 's/^display_errors = On/display_errors = Off/' "$tmp_php_ini"
        if ! grep -q "^opcache.enable" "$tmp_php_ini"; then
            cat <<EOF | sudo tee -a "$tmp_php_ini" > /dev/null

; OPcache settings for production
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
EOF
        fi
        sudo cp "$tmp_php_ini" "$PHP_INI"
        rm -f "$tmp_php_ini"
    else
        log_error "PHP configuration file not found at $PHP_INI."
    fi

    ############### Web Server Optimization ##################
    if [[ "${WEB_SERVER}" == "Nginx" ]]; then
        # Adjust configuration based on distribution
        local nginx_conf="/etc/nginx/nginx.conf"
        if [[ -f "$nginx_conf" ]]; then
            if [[ ! -f "${nginx_conf}.bak.lamp" ]]; then
                sudo cp "$nginx_conf" "${nginx_conf}.bak.lamp"
            fi
        fi

        # HTTP/2 and SSL listening should be added carefully, ideally when SSL certs are present.
        # For now, this part is commented out as it can break Nginx without certs.
        # Users should configure SSL and HTTP/2 manually or via a cert management tool.
        log_info "Nginx HTTP/2 & SSL: Manual configuration recommended. Ensure SSL certificates are in place before enabling."
        # if is_debian; then
        #     if [[ ${#DOMAIN_ARRAY[@]} -gt 0 ]]; then
        #         local first_domain_nginx_vhost="/etc/nginx/sites-available/${DOMAIN_ARRAY[0]}"
        #         if [[ -f "$first_domain_nginx_vhost" ]]; then
        #             # sudo sed -i '/listen 80;/a \    listen 443 ssl http2;' "$first_domain_nginx_vhost"
        #             log_info "To enable HTTP/2 for Nginx vhost $first_domain_nginx_vhost, add 'listen 443 ssl http2;' and SSL certificate directives."
        #         else
        #             log_warn "Nginx site configuration for first domain not found at $first_domain_nginx_vhost. HTTP/2 not automatically configured for vhost."
        #         fi
        #     else
        #         log_warn "No domains defined in DOMAIN_ARRAY. Cannot target specific Nginx vhost for HTTP/2 example."
        #     fi
        # else # RPM-based
        #     # sudo sed -i '/listen 80 default_server;/a \        listen 443 ssl http2 default_server;' "$nginx_conf" # Example for default_server
        #     log_info "To enable HTTP/2 for Nginx on RPM, modify the appropriate server block in $nginx_conf or /etc/nginx/conf.d/*.conf."

        # Enable Gzip compression if not already set
        if ! grep -q "gzip on;" /etc/nginx/nginx.conf; then
            sudo sed -i 's/http {*/http { \ngzip on;\ngzip_vary on;\ngzip_proxied any;\ngzip_comp_level 6;\ngzip_min_length 256;\ngzip_types text\/plain application\/xml application\/javascript text\/css;/' /etc/nginx/nginx.conf
        fi
        sudo systemctl reload nginx

    elif [[ "${WEB_SERVER}" == "Apache" ]]; then
        # Apache optimization with OS-specific paths and service names
        local apache_conf=""
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" || "$DISTRO" == "linuxmint" ]]; then
            apache_conf="/etc/apache2/apache2.conf"
            if [[ -f "$apache_conf" && ! -f "${apache_conf}.bak.lamp" ]]; then
                sudo cp "$apache_conf" "${apache_conf}.bak.lamp"
            fi
            enable_apache_module "headers"
            enable_apache_module "deflate"
            # Ensure mod_http2 is installed before enabling
            if ! sudo a2query -m http2 &>/dev/null; then
                log_info "Attempting to install mod_http2 for Apache on Debian-based system..."
                pkg_install libapache2-mod-http2 # Common package name
            fi
            enable_apache_module "http2"
            # Ensure Protocols directive includes h2
            if [ -f "$apache_conf" ]; then
                if ! grep -q "Protocols .*h2" "$apache_conf"; then
                    # Add or update Protocols line. Ensure h2 comes before h2c.
                    if grep -q "^Protocols " "$apache_conf"; then
                        sudo sed -i -E 's/^(Protocols\s+.*)(h2c\s+http\/1.1)/\1h2 \2/' "$apache_conf" # Add h2 if h2c http/1.1 exists
                        sudo sed -i -E 's/^(Protocols\s+.*)(http\/1.1)/\1h2 h2c \2/' "$apache_conf" # Add h2 h2c if only http/1.1 exists
                    fi
                    if ! grep -q "^Protocols " "$apache_conf"; then echo "Protocols h2 h2c http/1.1" | sudo tee -a "$apache_conf"; fi # Add if no Protocols line
                fi
            else
                log_warn "$apache_conf not found. Skipping Protocols update."
            fi
            sudo systemctl restart apache2
        else
            # For RHEL-based systems, Apache is usually installed as httpd
            apache_conf="/etc/httpd/conf/httpd.conf"
            if [[ -f "$apache_conf" && ! -f "${apache_conf}.bak.lamp" ]]; then
                sudo cp "$apache_conf" "${apache_conf}.bak.lamp"
            fi
            enable_apache_module "headers"
            enable_apache_module "deflate"
            # Ensure mod_http2 is installed before enabling
            if ! rpm -q mod_http2 &>/dev/null && ! httpd -M | grep -q http2_module; then
                log_info "Attempting to install mod_http2 for Apache on RPM-based system..."
                pkg_install mod_http2 # Common package name on RHEL 8+ / Fedora
            fi
            enable_apache_module "http2"
            # Ensure Protocols directive includes h2
            if [ -f "$apache_conf" ]; then
                if ! grep -q "Protocols .*h2" "$apache_conf"; then
                    if grep -q "^Protocols " "$apache_conf"; then
                        sudo sed -i -E 's/^(Protocols\s+.*)(h2c\s+http\/1.1)/\1h2 \2/' "$apache_conf"
                        sudo sed -i -E 's/^(Protocols\s+.*)(http\/1.1)/\1h2 h2c \2/' "$apache_conf"
                    fi
                    if ! grep -q "^Protocols " "$apache_conf"; then echo "Protocols h2 h2c http/1.1" | sudo tee -a "$apache_conf"; fi
                fi
            else
                log_warn "/etc/httpd/conf/httpd.conf not found. Skipping Protocols update."
            fi
            sudo systemctl restart httpd
        fi
    fi

    ############### Database Tuning ##################
    if [[ "${DB_ENGINE}" == "MySQL" || "${DB_ENGINE}" == "MariaDB" || "${DB_ENGINE}" == "Percona" ]]; then
        local MYSQL_CONF
        # Ubuntu/Debian commonly use /etc/mysql/my.cnf, while RHEL-based systems use /etc/my.cnf
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" || "$DISTRO" == "linuxmint" ]]; then
            MYSQL_CONF="/etc/mysql/my.cnf"
        else
            MYSQL_CONF="/etc/my.cnf"
        fi

        if [[ -f "$MYSQL_CONF" ]]; then
            if [[ ! -f "${MYSQL_CONF}.bak.lamp" ]]; then
                sudo cp "$MYSQL_CONF" "${MYSQL_CONF}.bak.lamp"
            fi
            # Check if [mysqld] section exists, add if not
            if ! grep -q "\[mysqld\]" "$MYSQL_CONF"; then sudo sed -i -e '$a\[mysqld]' "$MYSQL_CONF"; fi
            
            if ! grep -q "^innodb_buffer_pool_size" "$MYSQL_CONF"; then
                sudo sed -i "/\[mysqld\]/a innodb_buffer_pool_size=256M" "$MYSQL_CONF"
            else # If it exists, ensure it's not commented or update it
                sudo sed -i "s/^\s*#\s*innodb_buffer_pool_size\s*=.*/innodb_buffer_pool_size=256M/" "$MYSQL_CONF"
            fi
            if ! grep -q "^max_connections" "$MYSQL_CONF"; then sudo sed -i "/\[mysqld\]/a max_connections=150" "$MYSQL_CONF"
            else sudo sed -i "s/^\s*#\s*max_connections\s*=.*/max_connections=150/" "$MYSQL_CONF"; fi
            if ! grep -q "^thread_cache_size" "$MYSQL_CONF"; then sudo sed -i "/\[mysqld\]/a thread_cache_size=50" "$MYSQL_CONF"
            else sudo sed -i "s/^\s*#\s*thread_cache_size\s*=.*/thread_cache_size=50/" "$MYSQL_CONF"; fi

            # Restart the appropriate service name (mysql, mariadb, or mysqld)
            if systemctl is-active --quiet mysql; then
                sudo systemctl restart mysql
            elif systemctl is-active --quiet mariadb; then
                sudo systemctl restart mariadb
            elif systemctl is-active --quiet mysqld; then
                sudo systemctl restart mysqld
            fi
        else
            log_error "MySQL configuration file not found at $MYSQL_CONF"
        fi

    elif [[ "${DB_ENGINE}" == "PostgreSQL" ]]; then
        local PG_CONF
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" || "$DISTRO" == "linuxmint" ]]; then
            # Debian-based PostgreSQL location – dynamically locate the version folder
            PG_VERSION_DIR=$(ls /etc/postgresql 2>/dev/null | head -n1)
            PG_CONF="/etc/postgresql/${PG_VERSION_DIR}/main/postgresql.conf"
        else
            # RHEL-based distributions: default PostgreSQL config location; adjust if your version differs
            PG_CONF="/var/lib/pgsql/data/postgresql.conf"
        fi

        if [[ -f "$PG_CONF" ]]; then
            if [[ ! -f "${PG_CONF}.bak.lamp" ]]; then
                sudo cp "$PG_CONF" "${PG_CONF}.bak.lamp"
            fi
            if ! grep -q "^\s*shared_buffers\s*=\s*256MB" "$PG_CONF"; then # Check if already set correctly
                sudo sed -i "s/^\s*#\s*shared_buffers\s*=.*/shared_buffers = 256MB/" "$PG_CONF" # Uncomment or update
                if ! grep -q "^\s*shared_buffers\s*=" "$PG_CONF"; then echo "shared_buffers = 256MB" | sudo tee -a "$PG_CONF" > /dev/null; fi # Add if not found
            fi
            if ! grep -q "^\s*effective_cache_size\s*=\s*2GB" "$PG_CONF"; then
                sudo sed -i "s/^\s*#\s*effective_cache_size\s*=.*/effective_cache_size = 2GB/" "$PG_CONF"
                if ! grep -q "^\s*effective_cache_size\s*=" "$PG_CONF"; then echo "effective_cache_size = 2GB" | sudo tee -a "$PG_CONF" > /dev/null; fi
            fi
            # Attempt to restart PostgreSQL; try an alternative service name if needed
            sudo systemctl restart postgresql 2>/dev/null || sudo systemctl restart postgresql-12
        else
            log_error "PostgreSQL configuration file not found at $PG_CONF"
        fi
    fi
}


# Security hardening for PHP and SSH.
security_harden() {
    log_info "Starting security hardening procedures..."

    # Harden PHP configuration
    local PHP_INI
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -n "$PHP_INI" && -f "$PHP_INI" ]]; then
        if [[ ! -f "${PHP_INI}.sec.bak.lamp" ]]; then # Create backup only once
            sudo cp "$PHP_INI" "${PHP_INI}.sec.bak.lamp"
        fi
        local tmp_php_ini_sec
        tmp_php_ini_sec=$(mktemp)
        sudo cp "$PHP_INI" "$tmp_php_ini_sec"

        sudo sed -i 's/^expose_php = On/expose_php = Off/' "$tmp_php_ini_sec"
        sudo sed -i 's/^display_errors = On/display_errors = Off/' "$tmp_php_ini_sec"
        # Securely set disable_functions
        local disable_functions_line="disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,eval,dl,pcntl_exec"
        if grep -q "^\s*disable_functions\s*=" "$tmp_php_ini_sec"; then
            sudo sed -i "s|^\s*disable_functions\s*=.*|$disable_functions_line|" "$tmp_php_ini_sec"
        else
            echo "$disable_functions_line" | sudo tee -a "$tmp_php_ini_sec" > /dev/null
        fi
        sudo cp "$tmp_php_ini_sec" "$PHP_INI"
        rm -f "$tmp_php_ini_sec"
        # Set secure file permissions
        sudo chmod 644 "$PHP_INI"
        sudo chown root:root "$PHP_INI"
    else
        log_info "PHP configuration file not found; skipping PHP hardening."
    fi

    # Harden SSH configuration if requested
    if [[ "${USE_HARDENED_SSH:-false}" == true ]]; then
        harden_ssh_config
    else
        log_info "Standard SSH configuration will be applied (if SSH setup is chosen)."
        # setup_ssh_deployment handles the standard port change if USE_HARDENED_SSH is false
    fi

    # Configure automatic updates based on the OS
    if is_debian; then
        # For Ubuntu and Debian systems: unattended-upgrades is typically used.
        pkg_install unattended-upgrades
        sudo dpkg-reconfigure -plow unattended-upgrades || true
        log_info "Automatic updates configured via unattended-upgrades."
    elif [[ -f /etc/redhat-release || -f /etc/fedora-release ]]; then
        # For RedHat-based systems such as CentOS, Rocky Linux, AlmaLinux, Fedora, and RHEL
        if command -v dnf >/dev/null; then
            pkg_install dnf-automatic
            sudo systemctl enable --now dnf-automatic.timer || true
            log_info "Automatic updates configured via dnf-automatic."
        else
            pkg_install yum-cron
            sudo systemctl enable --now yum-cron || true
            log_info "Automatic updates configured via yum-cron."
        fi
    else
        log_warn "Automatic updates configuration not supported for this OS."
    fi

    # Ensure fail2ban service is active for brute-force prevention
    sudo systemctl enable --now fail2ban || true
    sudo systemctl restart fail2ban
    log_info "Security hardening complete."
}


# Harden SSH configuration
harden_ssh_config() {
    log_info "Applying hardened SSH configuration..."

    local SSH_CONFIG="/etc/ssh/sshd_config"
    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    if [[ ! -f "$SSH_CONFIG" ]]; then
        log_error "SSH configuration file ($SSH_CONFIG) not found. Skipping SSH hardening."
        return 1
    fi

    # Backup current configuration with a timestamp
    sudo cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.${TIMESTAMP}" || {
        log_error "Backup of $SSH_CONFIG failed. Aborting SSH hardening."
        return 1
    }

    # Change or insert a value in the config file:
    set_config() {
        local key="$1"
        local value="$2"
        # Use a more robust sed to handle various comment styles and existing values
        if grep -qE "^\s*#?\s*${key}\s+" "$SSH_CONFIG"; then
            sudo sed -i -E "s|^\s*#?\s*${key}\s+.*|${key} ${value}|" "$SSH_CONFIG"
        else
            echo "${key} ${value}" | sudo tee -a "$SSH_CONFIG" > /dev/null
        fi
    }
    
    # Define configuration settings as key-value pairs
    declare -A settings=(
        ["Protocol"]="2"
        ["PermitRootLogin"]="no"
        ["PasswordAuthentication"]="no"
        ["Port"]="2222"
        ["X11Forwarding"]="no"
        ["AllowAgentForwarding"]="no"
        ["PermitEmptyPasswords"]="no"
        ["ClientAliveInterval"]="300"
        ["ClientAliveCountMax"]="2"
        ["LoginGraceTime"]="30"
    )

    # Apply each configuration setting
    for key in "${!settings[@]}"; do
        set_config "$key" "${settings[$key]}"
    done

    # Append cryptographic settings if they don't exist
    if ! grep -q "^Ciphers" "$SSH_CONFIG"; then
        echo "Ciphers aes256-ctr,aes192-ctr,aes128-ctr" | sudo tee -a "$SSH_CONFIG" > /dev/null
    fi
    if ! grep -q "^MACs" "$SSH_CONFIG"; then
        echo "MACs hmac-sha2-512,hmac-sha2-256" | sudo tee -a "$SSH_CONFIG" > /dev/null
    fi
    if ! grep -q "^KexAlgorithms" "$SSH_CONFIG"; then
        echo "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" | sudo tee -a "$SSH_CONFIG" > /dev/null
    fi

    # Optionally set AllowUsers directive if environment variable SSH_ALLOWED_USERS is provided
    if [[ -n "${SSH_ALLOWED_USERS}" ]]; then
        set_config "AllowUsers" "${SSH_ALLOWED_USERS}"
    fi

    # Determine the SSH service name based on the operating system
    local SSH_SERVICE="sshd"  # default
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint)
                SSH_SERVICE="ssh"
                ;;
            centos|rocky|rhel|fedora|almalinux)
                SSH_SERVICE="sshd"
                ;;
            *)
                SSH_SERVICE="sshd"
                ;;
        esac
    fi

    # Reload the SSH daemon and check for success
    if sudo systemctl reload "$SSH_SERVICE"; then
        log_info "SSHD service reloaded successfully."
    else
        log_error "Failed to reload SSH service $SSH_SERVICE. Check 'sudo systemctl status $SSH_SERVICE' and 'sudo journalctl -xeu $SSH_SERVICE'."
        return 1
    fi

    log_info "Hardened SSH configuration applied."
}


setup_firewall() {
    log_info "Configuring firewall..."

    # ID and ID_LIKE should be globally available from init_distro
    # If /etc/os-release was not found or ID is not set, init_distro should have handled it or exited.
    if [[ -z "${ID:-}" ]]; then
        log_warn "Cannot detect operating system; /etc/os-release not found."
        return 1
    fi

    # Auto-detect the firewall tool if FIREWALL is unset or set to 'auto'
    if [ -z "$FIREWALL" ] || [ "$FIREWALL" = "auto" ]; then
        case "$ID" in
            ubuntu|debian)
                FIREWALL="ufw"
                ;;
            centos|rocky|almalinux|fedora|rhel)
                FIREWALL="firewalld"
                ;;
            *)
                if echo "$ID_LIKE" | grep -qi 'debian'; then
                    FIREWALL="ufw"
                elif echo "$ID_LIKE" | grep -qi 'rhel'; then
                    FIREWALL="firewalld"
                else
                    log_warn "Unsupported distribution ($ID); cannot determine firewall configuration automatically."
                    return 1
                fi
                ;;
        esac
    fi

    # Define common ports/services.
    HTTP_PORT=80
    HTTPS_PORT=443
    ALT_SSH_PORT=2222

    # Configure firewall according to the chosen tool.
    if [ "$FIREWALL" = "ufw" ]; then
        if command -v ufw >/dev/null 2>&1; then
            # Start UFW if it is not already active.
            UFW_STATUS=$(sudo ufw status | head -n1)
            if [ "$UFW_STATUS" != "Status: active" ]; then
                log_info "UFW is not active. Enabling UFW..."
                echo "y" | sudo ufw enable
            fi

            # Add firewall rules only if they are not already defined.
            if ! sudo ufw status | grep -q "${HTTP_PORT}/tcp"; then
                sudo ufw allow ${HTTP_PORT}/tcp
            fi
            if ! sudo ufw status | grep -q "${HTTPS_PORT}/tcp"; then
                sudo ufw allow ${HTTPS_PORT}/tcp
            fi
            if ! sudo ufw status | grep -q "${ALT_SSH_PORT}/tcp"; then
                sudo ufw allow ${ALT_SSH_PORT}/tcp
            fi

            # Verify UFW status.
            UFW_STATUS=$(sudo ufw status | head -n1)
            if [[ "$UFW_STATUS" == "Status: active" ]]; then
                log_info "UFW configured successfully on ${ID}."
                sudo ufw status numbered
            else
                log_warn "UFW does not appear to be active. Status: $UFW_STATUS"
                return 1
            fi
        else
            log_warn "UFW is not installed on this system."
            return 1
        fi

    elif [ "$FIREWALL" = "firewalld" ]; then
        if command -v firewall-cmd >/dev/null 2>&1; then

            # --- Check and install python3-nftables on RHEL-based distros ---
            if echo "$ID" | grep -Ei "centos|rocky|almalinux|rhel|fedora" >/dev/null; then
                if ! python3 -c "import nftables" >/dev/null 2>&1; then
                    log_info "python3-nftables is not installed. Attempting installation..."
                    if command -v dnf >/dev/null 2>&1; then
                        sudo dnf install -y python3-nftables
                    elif command -v yum >/dev/null 2>&1; then
                        sudo yum install -y python3-nftables
                    else
                        log_warn "No suitable package manager found to install python3-nftables."
                        echo "No suitable package manager found to install python3-nftables."
                    fi
                    if ! python3 -c "import nftables" >/dev/null 2>&1; then
                        log_warn "Failed to install python3-nftables. Firewall functionality may be affected."
                    else
                        log_info "python3-nftables installed successfully."
                    fi
                fi
            fi
            # --- End of python3-nftables check ---

            # Start firewalld if not already running using systemctl (if available).
            if command -v systemctl >/dev/null 2>&1; then
                FIREWALLD_STATE=$(sudo systemctl is-active firewalld)
                if [ "$FIREWALLD_STATE" != "active" ]; then
                    log_info "firewalld is not active. Starting firewalld..."
                    sudo systemctl start firewalld
                    sudo systemctl enable firewalld
                    FIREWALLD_STATUS_LOG=$(sudo systemctl status firewalld | grep "Active:" | head -n1)
                    log_info "firewalld status after start: $FIREWALLD_STATUS_LOG"
                fi
            fi

            # Add firewall rules using permanent configuration.
            if ! sudo firewall-cmd --list-ports | grep -q "${ALT_SSH_PORT}/tcp"; then
                sudo firewall-cmd --permanent --add-port=${ALT_SSH_PORT}/tcp
            fi
            sudo firewall-cmd --permanent --add-service=http
            sudo firewall-cmd --permanent --add-service=https

            # Reload firewalld rules and capture status.
            sudo firewall-cmd --reload
            RELOAD_STATUS=$?
            if [ $RELOAD_STATUS -ne 0 ]; then
                log_warn "firewalld reload failed with exit code $RELOAD_STATUS. This may be due to missing python3-nftables support, kernel restrictions, or SELinux policies. Check SELinux status with 'sestatus', install necessary packages (e.g., python3-nftables) or consider switching the backend to iptables in /etc/firewalld/firewalld.conf."
                return 1
            fi

            log_info "firewalld configured successfully on ${ID}."

            # Verify firewalld state, accepting both "running" and "active" as valid.
            FIREWALLD_STATE=$(sudo firewall-cmd --state 2>/dev/null)
            if [ "$FIREWALLD_STATE" == "running" ] || [ "$FIREWALLD_STATE" == "active" ]; then
                log_info "firewalld is running. Current firewalld settings:"
                sudo firewall-cmd --list-all
            else
                log_warn "firewalld does not appear to be running. State: $FIREWALLD_STATE"
                return 1
            fi
        else
            log_warn "firewall-cmd is not installed on this system."
            return 1
        fi
    else
        log_warn "Unsupported firewall configuration: $FIREWALL"
        return 1
    fi
}






# Setup SSH deployment user if requested.
setup_ssh_deployment() {
    log_info "Setting up SSH deployment environment..."

    # Install openssh-server using the available package manager.
    if command -v apt-get >/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y openssh-server || { log_error "Failed to install openssh-server via apt-get"; return 1; }
    elif command -v dnf >/dev/null; then
        sudo dnf install -y openssh-server || { log_error "Failed to install openssh-server via dnf"; return 1; }
    elif command -v yum >/dev/null; then
        sudo yum install -y openssh-server || { log_error "Failed to install openssh-server via yum"; return 1; }
    else
        log_error "Unsupported package manager. Please install openssh-server manually."
        return 1
    fi

    # Proceed only if SETUP_SSH_DEPLOY is explicitly set to true.
    if [[ "${SETUP_SSH_DEPLOY:-false}" == true ]]; then
        read -p "Enter deployment username (default: deploy): " DEPLOY_USER
        DEPLOY_USER=${DEPLOY_USER:-deploy}

        if id "$DEPLOY_USER" &>/dev/null; then
            log_info "User ${DEPLOY_USER} already exists."
        else
            # Source OS information for distribution-specific actions.
            if [ -f /etc/os-release ]; then
                . /etc/os-release
            fi

            # Create the user and add to the proper admin group.
            if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
                sudo adduser --disabled-password --gecos "" "$DEPLOY_USER" || { log_error "Failed to create user ${DEPLOY_USER}"; return 1; }
                sudo usermod -aG sudo "$DEPLOY_USER"
            elif [[ "$ID" =~ ^(centos|rocky|almalinux|fedora|rhel)$ ]]; then
                sudo useradd -m "$DEPLOY_USER" || { log_error "Failed to create user ${DEPLOY_USER}"; return 1; }
                sudo usermod -aG wheel "$DEPLOY_USER"
            else
                # Fallback if OS is not detected.
                sudo adduser --disabled-password --gecos "" "$DEPLOY_USER" || { log_error "Failed to create user ${DEPLOY_USER}"; return 1; }
                sudo usermod -aG sudo "$DEPLOY_USER"
            fi
            log_info "Created deployment user ${DEPLOY_USER}."
        fi

        # Set up the SSH directory and configure the authorized_keys file.
        local DEPLOY_AUTH_DIR="/home/${DEPLOY_USER}/.ssh"
        mkdir -p "$DEPLOY_AUTH_DIR"
        chmod 700 "$DEPLOY_AUTH_DIR"
        read -p "Enter public SSH key for ${DEPLOY_USER} (leave blank to skip): " DEPLOY_SSH_KEY
        if [[ -n "$DEPLOY_SSH_KEY" ]]; then
            echo "$DEPLOY_SSH_KEY" | tee "$DEPLOY_AUTH_DIR/authorized_keys" >/dev/null
            chmod 600 "$DEPLOY_AUTH_DIR/authorized_keys"
            sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_AUTH_DIR"
            log_info "SSH key added for ${DEPLOY_USER}."
        else
            log_info "No SSH key provided; skipping key configuration."
        fi
    fi

    # Update SSH configuration to listen on port 2222.
    # Determine the proper SSH service name based on the OS.
    local ssh_service="sshd"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            ssh_service="ssh"
        fi
    fi

    local ssh_config="/etc/ssh/sshd_config"
    # Create a backup of the original configuration if one doesn't exist.
    if [ ! -f "${ssh_config}.bak" ]; then
        sudo cp "$ssh_config" "${ssh_config}.bak"
    fi

    # Robustly set Port to 2222 if not hardened (hardened_ssh_config handles its own port)
    if [[ "${USE_HARDENED_SSH:-false}" == false ]]; then
        if sudo grep -qE "^\s*#?\s*Port\s+22\b" "$ssh_config"; then # If Port 22 is present (commented or not)
            sudo sed -i -E "s/^\s*#?\s*Port\s+22\b/Port 2222/" "$ssh_config"
        elif ! sudo grep -qE "^\s*Port\s+2222\b" "$ssh_config"; then # If Port 2222 is not already set
            echo "Port 2222" | sudo tee -a "$ssh_config" >/dev/null
        fi
        # Remove any other Port directives to ensure 2222 is the only one active (if not hardened)
        sudo sed -i "/^\s*Port\s+2222\b/!s/^\s*Port\s+.*//g" "$ssh_config" # Remove other Port lines
        sudo sed -i "/^\s*$/d" "$ssh_config" # Clean up empty lines that might result
    elif ! grep -qE "^\s*Port\s+2222\b" "$ssh_config"; then
        # If hardened SSH is chosen but somehow Port 2222 isn't set by harden_ssh_config, ensure it.
        echo "Port 2222" | sudo tee -a "$ssh_config" >/dev/null
    fi

    # Restart the SSH service using the proper service name.
    sudo systemctl restart "$ssh_service" || { log_error "Failed to restart SSH service (${ssh_service})"; return 1; }

    log_info "SSH deployment setup complete. SSH now set to listen on port 2222."
}


# Generate Docker Compose file.
generate_docker_compose() {
    log_info "Generating Docker Compose file..."
    cat <<EOF > docker-compose.yml
version: '3.8'
services:
  web:
    image: ${WEB_SERVER,,}
    ports:
      - "80:80"
      - "443:443"
EOF
    case "${DB_ENGINE}" in
        "MySQL"|"MariaDB"|"Percona")
            cat <<EOF >> docker-compose.yml
  db:
    image: mysql:5.7
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_PASSWORD}
EOF
            ;;
        "PostgreSQL")
            cat <<EOF >> docker-compose.yml
  db:
    image: postgres:latest
    environment:
      - POSTGRES_PASSWORD=${DB_PASSWORD}
EOF
            ;;
        "SQLite")
            echo "  # SQLite is file‑based. No dedicated container required." >> docker-compose.yml
            ;;
        "MongoDB")
            cat <<EOF >> docker-compose.yml
  db:
    image: mongo:latest
EOF
            ;;
        "OracleXE")
            echo "  # Oracle XE requires manual container configuration." >> docker-compose.yml
            ;;
    esac
    if [[ "${CACHE_SETUP}" == "Redis" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: redis:latest
EOF
    elif [[ "${CACHE_SETUP}" == "Memcached" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: memcached:latest
EOF
    elif [[ "${CACHE_SETUP}" == "Varnish" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: varnish:latest
EOF
    fi
    case "${MSG_QUEUE}" in
        "RabbitMQ")
            cat <<EOF >> docker-compose.yml
  mq:
    image: rabbitmq:management
EOF
            ;;
        "Kafka")
            cat <<EOF >> docker-compose.yml
  mq:
    image: confluentinc/cp-kafka:latest
EOF
            ;;
    esac
    log_info "Docker Compose file generated: docker-compose.yml"
}

# Generate Ansible playbook.
generate_ansible_playbook() {
    log_info "Generating Ansible playbook..."
    cat <<EOF > site.yml
- hosts: all
  become: true
  tasks:
    - name: Update package cache (Debian/Ubuntu)
      package:
        update_cache: yes
      when: ansible_os_family == "Debian"
      changed_when: false # Cache update itself doesn't mean a change in system state

    - name: Upgrade all packages
      package:
        name: '*' # Target all packages
        state: latest # Ensure they are at their latest version

    - name: Install essential packages
      package:
        name: "{{ item }}"
        state: present
      loop:
        - "{{ 'php' if ansible_os_family == 'Debian' else 'php-cli' }}" # Basic PHP CLI; full PHP setup is more complex
        - "{{ 'apache2' if ansible_os_family == 'Debian' else 'httpd' }}"
        - "{{ 'mariadb-server' if ansible_os_family == 'Debian' else 'mariadb-server' }}" # Or mysql-server
        # Add more packages as needed, with OS family considerations
EOF
    log_info "Ansible playbook generated: site.yml"
}


# -----------------------------------------------------------------------------
# Function: Enable Apache Modules
# -----------------------------------------------------------------------------
enable_apache_module() {
    local module_name="$1"
    local service_name=""
    # This variable could be used by the caller to decide if a reload/restart is needed.
    # For now, the caller (optimize_performance) handles restart explicitly.
    # local apache_config_changed=false 

    if is_debian; then
        service_name="apache2"
        log_info "Checking/Enabling Apache module '$module_name' on Debian-based system ($service_name)..."
        if ! sudo a2query -m "$module_name" &>/dev/null; then
            if sudo a2enmod "$module_name"; then
                log_info "Apache module '$module_name' enabled via a2enmod."
                # apache_config_changed=true # Caller will restart/reload
            else
                log_error "Failed to enable Apache module '$module_name' using a2enmod."
                # return 1 # Decide if this should be fatal
            fi
        else
            log_info "Apache module '$module_name' is already enabled (checked via a2query)."
        fi
    elif is_rpm; then
        service_name="httpd"
        log_info "Ensuring Apache module '$module_name' is available on RHEL-based system ($service_name)..."
        # For RHEL-based systems, modules are typically enabled via LoadModule directives
        # in /etc/httpd/conf.modules.d/ or main httpd.conf.
        # We assume that installing the 'httpd' package (and potentially 'mod_http2' if it were separate)
        # handles the necessary LoadModule lines.
        # A truly robust check would involve:
        # 1. Identifying the module file (e.g., mod_http2.so)
        # 2. Grepping through config files for "LoadModule http2_module" and ensuring it's not commented.
        # This is complex, so we rely on package management and the subsequent service restart.
        log_info "Verification for '$module_name' on RHEL relies on httpd package providing it and service restart."
    else
        log_warn "Unsupported distribution ('$DISTRO') for enable_apache_module."
        return 1
    fi
    return 0
}

install_phpmyadmin() {
    log_info "Starting phpMyAdmin installation..."

    if is_debian; then
        log_info "Updating package lists for Debian-based system..."
        sudo apt-get update -y # phpMyAdmin might need fresh lists
        log_info "Installing phpMyAdmin on Debian-based system..."
        # Pre-seed phpmyadmin selections to avoid interactive prompts.
        # Ensure DB_PASSWORD is set and not empty.
        local pma_db_password="${DB_PASSWORD:-}" 
        if [ -z "$pma_db_password" ]; then
            log_warn "DB_PASSWORD is not set. phpMyAdmin may prompt for password or use a random one."
        fi
        echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | sudo debconf-set-selections
        echo "phpmyadmin phpmyadmin/app-password-confirm password ${pma_db_password}" | sudo debconf-set-selections
        echo "phpmyadmin phpmyadmin/mysql/admin-pass password ${pma_db_password}" | sudo debconf-set-selections
        echo "phpmyadmin phpmyadmin/mysql/app-pass password ${pma_db_password}" | sudo debconf-set-selections
        echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | sudo debconf-set-selections # Adjust if using nginx
        export DEBIAN_FRONTEND=noninteractive
        pkg_install phpmyadmin # Uses apt-get via pkg_install
        unset DEBIAN_FRONTEND
    elif is_rpm; then
        # For RHEL-based distributions (CentOS, Rocky, AlmaLinux, RHEL) and Fedora
        # Ensure EPEL is enabled (install_prerequisites usually handles this, but good to double-check or ensure)
        if [[ "$DISTRO" =~ ^(centos|rocky|almalinux|rhel)$ ]] && ! rpm -qa | grep -qw epel-release; then
            log_info "EPEL repository not found or not enabled. Ensuring EPEL and PowerTools/CRB for phpMyAdmin..."
            enable_epel_and_powertools # Call the existing function
        fi
        log_info "Installing phpMyAdmin on RPM-based system..."
        pkg_install phpMyAdmin # Uses dnf/yum via pkg_install. Note CamelCase for RHEL.
    else
        log_error "phpMyAdmin installation not supported for distribution: $DISTRO"
        return 1
    fi

    log_info "phpMyAdmin installation process finished."
}


# Upgrade system and reconfigure services.
upgrade_system() {
    log_info "Starting upgrade process: This will uninstall existing components and then reinstall based on your selections."
    echo "WARNING: The upgrade process involves uninstalling currently installed components"
    echo "managed by this script, and then reinstalling them. You will be prompted"
    echo "again before the uninstallation begins within the uninstall routine."
    read -rp "Are you sure you want to proceed with the upgrade (uninstall then reinstall)? (y/N): " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log_info "Upgrade aborted by user."
        exit 0
    fi

    local total_upgrade_steps=2
    local current_upgrade_step=0
    display_progress "$current_upgrade_step" "$total_upgrade_steps" "Upgrade Initializing"

    log_info "Proceeding with uninstallation phase of the upgrade..."
    uninstall_components
    # uninstall_components will exit if the user aborts its specific confirmation.

    log_info "Proceeding with reinstallation phase of the upgrade..."
    # The install_prerequisites function (called by install_standard/install_lamp)
    # will handle pkg_update.
    if [[ "${INSTALL_TYPE}" == "standard" ]]; then
        install_standard
    else
        install_lamp
    fi
    current_upgrade_step=$((current_upgrade_step + 1))
    display_progress "$current_upgrade_step" "$total_upgrade_steps" "Upgrade: Reinstallation Complete"

    log_info "✅ Upgrade process (uninstall and reinstall) has completed."
}

# Uninstall components
uninstall_components() {
    log_info "Preparing to uninstall components..."

    # Base list of packages for removal
    # This is a comprehensive list of software this script *might* install.
    # The remove_if_installed function will only attempt to remove packages that are actually present.
    local PACKAGES_TO_REMOVE=( \
        "apache2" "apache2-utils" "nginx" "caddy" "lighttpd" \
        "mysql-server" "mariadb-server" "percona-server-server" "postgresql" \
        "mongodb-org" \ # For MongoDB
        "phpmyadmin" \ # phpMyAdmin (lowercase for Debian/Ubuntu)
        "certbot" "${FIREWALL}" "vsftpd" "unattended-upgrades" "fail2ban" \
        "redis-server" "redis" \ # redis-server (Debian), redis (RPM)
        "memcached" \
        "varnish" \
        "rabbitmq-server" \
        "openjdk-11-jdk" "java-11-openjdk-devel" \ # Java for Kafka
    )
    # For RPM-based systems (CentOS, RHEL, Rocky Linux, AlmaLinux), phpMyAdmin may be installed with different case.
    if is_rpm; then
        PACKAGES_TO_REMOVE+=( "phpMyAdmin" ) # phpMyAdmin (CamelCase for RHEL-based)
    fi

    # Dynamically find installed PHP packages
    local installed_php_packages=()
    if is_debian; then
        installed_php_packages=($(dpkg-query -W -f='${Package}\n' 'php*' | grep -E '^php[0-9.]*(-[a-zA-Z0-9]+)*$' || true))
    elif is_rpm; then
        installed_php_packages=($(rpm -qa 'php*' | grep -E '^php[0-9.]*(-[a-zA-Z0-9]+)*$' || true))
    fi

    PACKAGES_TO_REMOVE+=("${installed_php_packages[@]}")
    log_info "Packages identified for removal: ${PACKAGES_TO_REMOVE[*]}"

    # Configuration and application-specific directories/files for removal.
    # These are generally safe to remove if the corresponding software is uninstalled.
    # Data directories (like /var/lib/mysql) are NOT included here and should be handled manually.
    local CONFIG_APP_ITEMS_TO_REMOVE=( \
        "/etc/apache2" "/etc/httpd" \
        "/etc/nginx" \
        "/etc/caddy" \
        "/etc/lighttpd" \
        "/etc/php" \ # This will remove all PHP version configs
        "/etc/mysql" "/etc/my.cnf" "/etc/my.cnf.d" "/etc/alternatives/my.cnf" \
        "/etc/postgresql" \
        "/etc/mongodb" "/etc/mongod.conf" \
        "/etc/phpmyadmin" "/etc/phpMyAdmin" "/usr/share/phpmyadmin" "/usr/share/phpMyAdmin" \
        "/etc/vsftpd" "/etc/vsftpd.conf" \
        "/etc/redis" "/etc/redis.conf" \
        "/etc/memcached.conf" \
        "/etc/varnish" \
        "/etc/rabbitmq" \
        "/opt/kafka" \ # Kafka base directory installed by this script
        "/etc/systemd/system/zookeeper.service" "/etc/systemd/system/kafka.service" \ # Kafka service files
        "/etc/letsencrypt" \
        "/etc/fail2ban" \
        "/etc/unattended-upgrades" \
        "./docker-compose.yml" "./site.yml" \ # Script-generated files in CWD
    )

    echo "WARNING: The following packages and directories will be removed:"
    echo "Packages (if installed):"
    for item in "${PACKAGES_TO_REMOVE[@]}"; do
        echo "   - $item"
    done
    echo "Configuration/Application files and directories (if they exist):"
    for item in "${CONFIG_APP_ITEMS_TO_REMOVE[@]}"; do
        echo "   - $item"
    done
    echo ""
    echo "IMPORTANT: This script will NOT automatically remove:"
    echo "  - User data directories (e.g., /var/lib/mysql, /var/lib/pgsql, /var/lib/mongodb, /var/lib/rabbitmq)."
    echo "  - Web server document roots (e.g., /var/www/html or custom DOC_ROOT) and their content."
    echo "  - The log file for this script (${LOGFILE:-not set, will be in your Desktop or home dir})."
    echo "Please back up and remove these manually if desired."

    read -rp "Are you sure you want to proceed? This action cannot be reversed! (y/N): " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation aborted by user."
        exit 0
    fi

    local total_uninstall_steps=6 # Approximate steps for progress bar
    local current_uninstall_step=0
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Starting"

    log_info "Stopping services..."
    # Add httpd for RHEL-based Apache, redis for RPM redis, kafka, zookeeper
    for service in apache2 httpd nginx caddy lighttpd mysql mariadb postgresql mongod redis redis-server memcached varnish rabbitmq-server kafka zookeeper vsftpd fail2ban unattended-upgrades; do
        sudo systemctl stop "$service" 2>/dev/null || true
    done
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Services Stopped"

    log_info "Removing packages..."
    for pkg in "${PACKAGES_TO_REMOVE[@]}"; do
        remove_if_installed "$pkg"
    done
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Packages Removed"

    log_info "Removing configuration/application files and directories..."
    for item in "${CONFIG_APP_ITEMS_TO_REMOVE[@]}"; do
        if [[ -e "$item" ]]; then # Check if file or directory exists
            log_info "Removing $item..."
            sudo rm -rf "$item"
        fi
    done
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Configs Removed"

    if [[ "$FIREWALL" == "ufw" && $(command -v ufw) ]]; then
        sudo ufw disable || true
    else
        sudo systemctl stop firewalld || true
        sudo systemctl disable firewalld || true
    fi
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Firewall Disabled"

    # Reload systemd daemon if service files were removed
    sudo systemctl daemon-reload
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: Daemon Reloaded"

    if is_debian; then
        sudo apt-get autoremove -y && sudo apt-get autoclean
    else
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf autoremove -y
        else
            sudo yum autoremove -y
        fi
    fi
    current_uninstall_step=$((current_uninstall_step + 1))
    display_progress "$current_uninstall_step" "$total_uninstall_steps" "Uninstall: System Cleaned"

    log_info "Uninstallation complete."
}



##############################
# Installation Modes
##############################

install_standard() {
    log_info "Starting Standard LAMP installation (Apache, MariaDB, PHP, phpMyAdmin)..."
    local total_steps=12
    local current_step=0
    display_progress "$current_step" "$total_steps" "Install: Initializing"

    install_prerequisites; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Prerequisites"
    prepare_docroot; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Document Root"
    install_php; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: PHP"
    install_database; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Database"
    install_web_server; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Web Server"
    setup_virtual_hosts; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Virtual Hosts"
    install_phpmyadmin; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: phpMyAdmin"
    optimize_performance; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Optimizing Performance"
    setup_firewall; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Firewall"
    security_harden; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Security Hardening"
    setup_ssh_deployment; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: SSH Deployment"

    if [[ "${WEB_SERVER}" == "Apache" ]]; then
        log_info "Restarting Apache..."
        sudo systemctl restart "$APACHE_PACKAGE"
        sudo systemctl status "$APACHE_PACKAGE"
    fi
    current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Install: Finalizing"

    log_info "✅ Standard LAMP installation is complete!"
    echo "Detailed log file saved at: ${LOGFILE}"
}

install_lamp() {
    local total_steps=10 # Base steps for mandatory components
    local current_step=0

    # Dynamically calculate total_steps based on user selections for optional components
    [[ "${INSTALL_FTP:-false}" == true ]] && total_steps=$((total_steps + 1))
    [[ "${CACHE_SETUP}" != "None" ]] && total_steps=$((total_steps + 1))
    [[ "${MSG_QUEUE}" != "None" ]] && total_steps=$((total_steps + 1))
    [[ "${GENERATE_DOCKER:-false}" == true ]] && total_steps=$((total_steps + 1))
    [[ "${GENERATE_ANSIBLE:-false}" == true ]] && total_steps=$((total_steps + 1))

    log_info "Starting Advanced Installation..."
    display_progress "$current_step" "$total_steps" "Adv. Install: Initializing"

    install_prerequisites; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Prerequisites"
    prepare_docroot; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Document Root"
    install_php; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: PHP"
    install_database; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Database"

    if [[ "${INSTALL_FTP:-false}" == true ]]; then
        install_ftp_sftp; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: FTP/SFTP"
    fi
    if [[ "${CACHE_SETUP}" != "None" ]]; then
        install_cache; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Cache (${CACHE_SETUP})"
    fi
    if [[ "${MSG_QUEUE}" != "None" ]]; then
        install_messaging_queue; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Queue (${MSG_QUEUE})"
    fi

    install_web_server; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Web Server (${WEB_SERVER})"
    setup_virtual_hosts; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Virtual Hosts"
    optimize_performance; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Optimizing"
    setup_firewall; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Firewall"
    security_harden; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Hardening"
    setup_ssh_deployment; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: SSH"

    if [[ "${GENERATE_DOCKER:-false}" == true ]]; then
        generate_docker_compose; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Docker"
    fi
    if [[ "${GENERATE_ANSIBLE:-false}" == true ]]; then
        generate_ansible_playbook; current_step=$((current_step + 1)); display_progress "$current_step" "$total_steps" "Adv. Install: Ansible"
    fi

    # Ensure progress reaches 100% if all steps are done by making sure current_step matches total_steps
    if [[ "$current_step" -lt "$total_steps" ]]; then
        log_warn "Progress step mismatch. Expected $total_steps, got $current_step. Forcing to 100%."
        current_step=$total_steps
    fi
    display_progress "$current_step" "$total_steps" "Adv. Install: Finalizing"
    log_info "✅ Advanced installation is complete!"
    echo "Detailed log file saved at: ${LOGFILE}"
}

install_prerequisites() {
    pkg_update
    if is_debian; then
        pkg_install software-properties-common openssh-server ufw fail2ban
    else
        pkg_install openssh-server firewalld fail2ban # firewalld is default on many RPM systems
        enable_epel_and_powertools # Ensure EPEL and PowerTools/CRB are set up early
    fi
    if [[ "${INSTALL_UTILS:-false}" == true ]]; then
        pkg_install git curl htop zip unzip
    fi
}

##############################
# Main Interactive Flow
##############################
main() {
    # Initialize distro and set global variables.
    DISTRO=$(init_distro)
    log_info "Running the script on: ${DISTRO}"

    # Define LOGFILE path - moved up to log early
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        USER_HOME=$(eval echo "~$SUDO_USER")
    else
        USER_HOME=$HOME
    fi
    if [[ -d "$USER_HOME/Desktop" ]]; then
        LOGFILE="$USER_HOME/Desktop/installer.log"
    else
        LOGFILE="$USER_HOME/installer.log"
    fi
    echo "Installation script started at $(date)" > "$LOGFILE" # Initial log entry
    exec > >(tee -a "$LOGFILE") 2>&1 # Start logging all output

    if is_debian; then
        APACHE_PACKAGE="apache2"
        JAVA_PACKAGE="openjdk-11-jdk"
        FIREWALL="ufw"
    else
        APACHE_PACKAGE="httpd"
        JAVA_PACKAGE="java-11-openjdk-devel"
        FIREWALL="firewalld"
    fi

    # Set default DocumentRoot if not already set.
    DOC_ROOT=${DOC_ROOT:-/var/www/html}

    # Display Banner (you can customize or remove the ASCII art as needed)
    RED='\033[0;31m'
    NC='\033[0m'
    ART=(
    "   _        _______  _______  _______    ______                                _        _______ _________ _______   "
    "  ( \      (  ___  )(       )(  ____ )  (  ___ \ |\     /|  |\     /||\     /|( \      ( ____ \\__   __/(  ____ \  "
    "  | (      | (   ) || () () || (    )|  | (   ) )( \   / )  | )   ( || )   ( || (      | (    \/   ) (   | (    \/  "
    "  | |      | (___) || || || || (____)|  | (__/ /  \ (_) /   | | _ | || |   | || |      | (__       | |   | |        "
    "  | |      |  ___  || |(_)| ||  _____)  |  __ (    \   /    | |( )| || |   | || |      |  __)      | |   | |        "
    "  | |      | (   ) || |   | || (        | (  \ \    ) (     | || || || |   | || |      | (         | |   | |        "
    "  | (____/\| )   ( || )   ( || )        | )___) )   | |     | () () || (___) || (____/\| )      ___) (___| (____/\  "
    "  (_______/|/     \||/     \||/         |/ \___/    \_/     (_______)(_______)(_______/|/       \_______/(_______/  "
    "###########################################################################################################"
    "#################################### Lamp by Wulfic #####################################################"
    "01001100 01100001 01101101 01110000  01100010 01111001  01010111 01110101 01101100 01100110 01101001 01100011 "
    )
    for line in "${ART[@]}"; do
        printf "${RED}%s\n" "$line"
    done
    printf "${NC}\n"  # Reset color	
echo ""	
echo "##########################################################################"
echo "# Enhanced Multi‑Engine Server Installer & Deployment Script"
echo "# Supports Ubuntu, Debian, CentOS, Rocky Linux, AlmaLinux, Fedora, Linux Mint, and RHEL"
echo "#"
echo "# This script installs a flexible stack with options for:"
echo "# • Multiple database engines: MySQL, MariaDB, PostgreSQL, SQLite, Percona, MongoDB, OracleXE"
echo "# • Multiple web servers: Apache (or httpd on RPM‑based systems), Nginx, Caddy, Lighttpd"
echo "# • Extended caching: Redis (or redis on RPM‑based systems), Memcached, Varnish"
echo "# • Messaging queues: RabbitMQ, Kafka"
echo "# • Containerization & automation support: Docker Compose file generation, Ansible playbook export"
echo "# • SSH Setup Options: Standard SSH or Hardened SSH (Protocol 2, key‑only auth, custom ciphers, etc.)"
echo "#"
echo "# IMPORTANT:"
echo "#   - OracleXE is not supported automatically."
echo "#   - Varnish caching is only allowed with Nginx."
echo "#   - A log file (\"installer.log\") is created on your Desktop or home directory."
echo "#"
echo "# Note: This version includes distro‑specific adjustments and logging for easier debugging."
echo "##########################################################################"

    # User interactive prompts (skip for uninstall mode)
    if [[ "${MODE:-}" != "uninstall" ]]; then
        echo "Choose an operation:"
        select ACTION in "Install" "Upgrade" "Uninstall"; do
            case $ACTION in
                Install ) MODE="install"; break;;
                Upgrade ) MODE="upgrade"; break;;
                Uninstall ) MODE="uninstall"; break;;
            esac
        done

        if [[ "$MODE" != "uninstall" ]]; then
            echo "Select installation type:"
            select INSTALL_TYPE in "Standard LAMP" "Advanced Installation"; do
                case $INSTALL_TYPE in
                    "Standard LAMP") INSTALL_TYPE="standard"; break;;
                    "Advanced Installation") INSTALL_TYPE="advanced"; break;;
                esac
            done

            # Common prompts
            read -s -p "Enter a default password for DB and admin panels: " DB_PASSWORD
            echo
            read -p "Enter domain name(s) (comma-separated): " DOMAINS
            if [[ -z "$DOMAINS" ]]; then
                log_error "No domains provided. Exiting."
                exit 1
            fi
            IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
            if [[ ${#DOMAIN_ARRAY[@]} -eq 0 ]]; then
                log_error "No valid domains provided. Exiting."
                exit 1
            fi
            read -p "Enter document root directory (default: /var/www/html): " DOC_ROOT
            DOC_ROOT=${DOC_ROOT:-/var/www/html}

            if [[ "$INSTALL_TYPE" == "standard" ]]; then
                DB_ENGINE="MariaDB"
                WEB_SERVER="Apache"
                PHP_VERSION=$(best_php_version)
                INSTALL_UTILS=false
                INSTALL_FTP=false
                CACHE_SETUP="None"
                MSG_QUEUE="None"
                USE_HARDENED_SSH=false
                GENERATE_DOCKER=false
                GENERATE_ANSIBLE=false
                log_info "Standard LAMP installation selected: Apache, MariaDB, PHP, and phpMyAdmin."
            else
                PHP_VERSION=$(best_php_version)
                echo "Auto-selected best PHP version: ${PHP_VERSION}"
                echo "Select database engine:"
                select DB_ENGINE in "MySQL" "MariaDB" "PostgreSQL" "SQLite" "Percona" "MongoDB" "OracleXE"; do break; done
                echo "Install optional tools (git, curl, htop, zip, etc.)?"
                select UTIL_TOOLS in "Yes" "No"; do
                    [[ "$UTIL_TOOLS" == "Yes" ]] && INSTALL_UTILS=true || INSTALL_UTILS=false; break
                done
                echo "Install FTP/SFTP server?"
                select FTP_SETUP in "Yes" "No"; do
                    [[ "$FTP_SETUP" == "Yes" ]] && INSTALL_FTP=true || INSTALL_FTP=false; break
                done
                echo "Enable caching (Redis/Memcached/Varnish)?"
                select CACHE_SETUP in "Redis" "Memcached" "Varnish" "None"; do break; done
                echo "Select messaging queue engine:"
                select MSG_QUEUE in "RabbitMQ" "Kafka" "None"; do break; done
                echo "Select web server:"
                select WEB_SERVER in "Nginx" "Apache" "Caddy" "Lighttpd"; do break; done
                echo "Setup SSH deployment user?"
                select SSH_DEPLOY in "Yes" "No"; do
                    [[ "$SSH_DEPLOY" == "Yes" ]] && SETUP_SSH_DEPLOY=true || SETUP_SSH_DEPLOY=false; break
                done
                echo "Restrict SSH logins to specific users? (Optional)"
                read -p "Enter allowed SSH usernames (space‑separated, leave empty for all): " SSH_ALLOWED_USERS
                echo "Select SSH configuration type:"
                select SSH_CONFIG_OPTION in "Standard SSH" "Hardened SSH"; do
                    case $SSH_CONFIG_OPTION in
                        "Standard SSH" ) USE_HARDENED_SSH=false; break;;
                        "Hardened SSH" ) USE_HARDENED_SSH=true; break;;
                    esac
                done
                echo "Generate Docker Compose file for containerized deployment?"
                select DOCKER_OPTION in "Yes" "No"; do
                    [[ "$DOCKER_OPTION" == "Yes" ]] && GENERATE_DOCKER=true || GENERATE_DOCKER=false; break
                done
                echo "Generate Ansible playbook for automation?"
                select ANSIBLE_OPTION in "Yes" "No"; do
                    [[ "$ANSIBLE_OPTION" == "Yes" ]] && GENERATE_ANSIBLE=true || GENERATE_ANSIBLE=false; break
                done
            fi
        fi
    fi

    # Final mode selection and execution
    case "$MODE" in
        install)
            if [[ "$INSTALL_TYPE" == "standard" ]]; then
                install_standard
            else
                install_lamp
            fi
            ;;
        upgrade)
            upgrade_system
            ;;
        uninstall)
            uninstall_components
            ;;
    esac

    if [[ "$MODE" != "uninstall" && -n "$LOGFILE" ]]; then
        echo "Detailed log file saved at: $LOGFILE"
    fi
}

# Now execute the main function.
main
