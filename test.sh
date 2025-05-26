#!/bin/bash
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
    local msg="$1"
    local func="${FUNCNAME[1]:-main}"
    local line="${BASH_LINENO[0]:-unknown}"
    echo "ERROR in ${func} at line ${line}: $msg" >&2
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') ERROR in ${func} (line ${line}): $msg" >> "$LOGFILE"
    fi
}

log_info() {
    local msg="$1"
    if [[ "${VERBOSE}" == true ]]; then
        echo "INFO: $msg"
    fi
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$(date +'%Y-%m-%d %T') INFO: $msg" >> "$LOGFILE"
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

# Determine the Linux distribution
	if [ -f /etc/os-release ]; then
	  . /etc/os-release
	  DISTRO_ID=$ID
	else
	  DISTRO_ID=$(uname -s)
	fi

	echo "Detected distribution: $DISTRO_ID"

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
	echo "Updating system on $DISTRO..."
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
        sudo dnf install -y epel-release || true
        if grep -q "Rocky Linux 9" /etc/os-release; then
            log_info "Enabling CodeReady Builder (CRB) repository for Rocky Linux 9..."
            sudo dnf config-manager --set-enabled crb || true
        else
            log_info "Enabling PowerTools repository..."
            sudo dnf config-manager --set-enabled powertools || true
        fi
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y epel-release || true
        sudo yum-config-manager --enable epel || true
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
                if dnf info php | grep -E -q "Version\s*:\s*${ver}\b"; then
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
            pkg_install php-sqlite3 sqlite
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
        if ! sudo dnf module install php:remi-"${PHP_VERSION}" -y; then
            log_error "Failed to install php:remi-${PHP_VERSION} module group"
            exit 3
        fi

        sudo dnf clean all && sudo dnf makecache
        pkg_install "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysqlnd" \
                    "php${PHP_VERSION}-gd" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-mbstring" \
                    "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip"
        if [[ "${DB_ENGINE:-MariaDB}" == "SQLite" ]]; then
            pkg_install php-sqlite3 sqlite
        fi
    fi
}

install_database() {
    log_info "Installing database engine: ${DB_ENGINE}"
    echo "Installing database engine: ${DB_ENGINE}"
    if [[ "${DB_ENGINE}" == "MySQL" && ( "$DISTRO" =~ ^(centos|rhel|rocky|almalinux)$ ) ]]; then
        log_info "MySQL not available by default on $DISTRO; switching to MariaDB."
        DB_ENGINE="MariaDB"
    fi

    # Helper to fix package misconfigurations on Debian-based systems.
    fix_pkg_misconfigs() {
        log_info "Attempting to fix package misconfigurations with 'apt-get install -f' and 'dpkg --configure -a'."
        echo "Attempting to fix package misconfigurations with 'apt-get install -f' and 'dpkg --configure -a'."
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
            # On Linux Mint, force reinstallation of mariadb-common to work around post-install script error.
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

            # Detect the installed MariaDB version to decide which SQL commands to run.
            local mariadb_version version_major version_minor auth_plugin
            mariadb_version=$(sudo mysql -N -e "SELECT VERSION();" 2>/dev/null | cut -d'-' -f1)
            if [[ -z "$mariadb_version" ]]; then
                log_error "Failed to detect MariaDB version."
                return 1
            fi
            version_major=$(echo "$mariadb_version" | cut -d. -f1)
            version_minor=$(echo "$mariadb_version" | cut -d. -f2)
            log_info "Detected MariaDB version: $mariadb_version"

            log_info "Configuring MariaDB..."
            if [[ $version_major -eq 10 && $version_minor -lt 4 ]]; then
                log_info "Older MariaDB version detected (<10.4): Using legacy password configuration."
                auth_plugin=$(sudo mysql -N -e "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" 2>/dev/null || echo '')
                if [[ "$auth_plugin" == "unix_socket" || "$auth_plugin" == "auth_socket" ]]; then
                    sudo mysql <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_PASSWORD}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
                else
                    if [[ -z "${CURRENT_ROOT_PASSWORD:-}" ]]; then
                        read -s -p "Enter current MariaDB root password (Hint:Same password you setup at the start): " CURRENT_ROOT_PASSWORD
                        echo
                    fi
                    if [[ -n "$CURRENT_ROOT_PASSWORD" ]]; then
                        sudo mysql -uroot -p"${CURRENT_ROOT_PASSWORD}" <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_PASSWORD}');
FLUSH PRIVILEGES;
EOF
                    else
                        sudo mysql -uroot <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_PASSWORD}');
FLUSH PRIVILEGES;
EOF
                    fi
                fi
            else
                # For MariaDB versions 10.4 and up, use the ALTER USER syntax.
                if [[ $version_major -eq 10 && $version_minor -ge 4 ]]; then
                    sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
                else
                    auth_plugin=$(sudo mysql -N -e "SELECT plugin FROM mysql.user WHERE user='root' AND host='localhost';" 2>/dev/null || echo '')
                    if [[ "$auth_plugin" == "unix_socket" || "$auth_plugin" == "auth_socket" ]]; then
                        sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
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
                log_info "Caddy installation on $DISTRO may require manual intervention."
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
    if [[ "${WEB_SERVER}" == "Nginx" ]]; then
        for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
            DOMAIN=$(echo "$DOMAIN" | xargs)
            mkdir -p "${DOC_ROOT}/${DOMAIN}"
            cat <<EOF | sudo tee /etc/nginx/sites-available/"${DOMAIN}"
server {
    listen 80;
    server_name ${DOMAIN};
    root ${DOC_ROOT}/${DOMAIN};
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
            sudo ln -sf /etc/nginx/sites-available/"${DOMAIN}" /etc/nginx/sites-enabled/
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
    echo "optimizing system performance..."

    # PHP configuration adjustments
    local PHP_INI
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -f "$PHP_INI" ]]; then
        sudo cp "$PHP_INI" "${PHP_INI}.bak"
        sudo sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI"
        sudo sed -i 's/display_errors = On/display_errors = Off/' "$PHP_INI"
        if ! grep -q "opcache.enable" "$PHP_INI"; then
            cat <<EOF | sudo tee -a "$PHP_INI"

; OPcache settings for production
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
EOF
        fi
    else
        log_error "PHP configuration file not found at $PHP_INI."
    fi

    # Determine the Linux distribution using /etc/os-release
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
    else
        DISTRO="unknown"
    fi

    ############### Web Server Optimization ##################
    if [[ "${WEB_SERVER}" == "Nginx" ]]; then
        # Adjust configuration based on distribution
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" || "$DISTRO" == "linuxmint" ]]; then
            # Debian-based systems typically use sites-available
            if [[ -f /etc/nginx/sites-available/"${DOMAIN_ARRAY[0]}" ]]; then
                sudo sed -i '/listen 80;/a listen 443 ssl http2;' /etc/nginx/sites-available/"${DOMAIN_ARRAY[0]}"
            else
                log_error "Nginx site configuration /etc/nginx/sites-available/${DOMAIN_ARRAY[0]} not found."
            fi
        else
            # RHEL-based distributions – modify the main config
            sudo sed -i '/listen 80;/a listen 443 ssl http2;' /etc/nginx/nginx.conf
        fi

        # Enable Gzip compression if not already set
        if ! grep -q "gzip on;" /etc/nginx/nginx.conf; then
            sudo sed -i 's/http {*/http { \ngzip on;\ngzip_vary on;\ngzip_proxied any;\ngzip_comp_level 6;\ngzip_min_length 256;\ngzip_types text\/plain application\/xml application\/javascript text\/css;/' /etc/nginx/nginx.conf
        fi
        sudo systemctl reload nginx

    elif [[ "${WEB_SERVER}" == "Apache" ]]; then
        # Apache optimization with OS-specific paths and service names
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" || "$DISTRO" == "linuxmint" ]]; then
            enable_apache_module "deflate"
            enable_apache_module "http2"
            sudo sed -i 's/Protocols h2 http\/1.1/Protocols h2 http\/1.1/' /etc/apache2/apache2.conf
            sudo systemctl restart apache2
        else
            # For RHEL-based systems, Apache is usually installed as httpd
            enable_apache_module "deflate"
            enable_apache_module "http2"
            sudo sed -i 's/Protocols h2 http\/1.1/Protocols h2 http\/1.1/' /etc/httpd/conf/httpd.conf
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
            if ! grep -q "innodb_buffer_pool_size" "$MYSQL_CONF"; then
                cat <<EOF | sudo tee -a "$MYSQL_CONF"

[mysqld]
innodb_buffer_pool_size=256M
max_connections=150
thread_cache_size=50
EOF
            fi
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
            sudo sed -i "s/#shared_buffers = 128MB/shared_buffers = 256MB/" "$PG_CONF"
            sudo sed -i "s/#effective_cache_size = 4GB/effective_cache_size = 2GB/" "$PG_CONF"
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
	echo "Starting security hardening procedures..."

    # Harden PHP configuration
    local PHP_INI
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -f "$PHP_INI" ]]; then
        sudo cp "$PHP_INI" "${PHP_INI}.sec.bak"
        sudo sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI"
        sudo sed -i 's/display_errors = On/display_errors = Off/' "$PHP_INI"
        if ! grep -q "^disable_functions" "$PHP_INI"; then
            # Expanded the function list for tighter security
            echo "disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,eval,dl,pcntl_exec" | sudo tee -a "$PHP_INI"
        fi
        # Set secure file permissions
        sudo chmod 644 "$PHP_INI"
        sudo chown root:root "$PHP_INI"
    else
        log_info "PHP configuration file not found; skipping PHP hardening."
		echo "PHP configuration file not found; skipping PHP hardening."
    fi

    # Harden SSH configuration if requested
    if [[ "${USE_HARDENED_SSH:-false}" == true ]]; then
        harden_ssh_config
    else
        log_info "Standard SSH configuration applied."
		echo "Standard SSH configuration applied."
    fi

    # Configure automatic updates based on the OS
    if is_debian; then
        # For Ubuntu and Debian systems: unattended-upgrades is typically used.
        pkg_install unattended-upgrades
        sudo dpkg-reconfigure -plow unattended-upgrades || true
        log_info "Automatic updates configured via unattended-upgrades (Ubuntu/Debian)."
		echo "Automatic updates configured via unattended-upgrades (Ubuntu/Debian)."
    elif [[ -f /etc/redhat-release || -f /etc/fedora-release ]]; then
        # For RedHat-based systems such as CentOS, Rocky Linux, AlmaLinux, Fedora, and RHEL
        if command -v dnf >/dev/null; then
            pkg_install dnf-automatic
            sudo systemctl enable --now dnf-automatic.timer || true
            log_info "Automatic updates configured via dnf-automatic (Modern RedHat-based system)."
			echo "Automatic updates configured via dnf-automatic (Modern RedHat-based system)."
        else
            pkg_install yum-cron
            sudo systemctl enable --now yum-cron || true
            log_info "Automatic updates configured via yum-cron (Legacy RedHat-based system)."
			echo "Automatic updates configured via yum-cron (Legacy RedHat-based system)."
        fi
    else
        log_info "Automatic updates configuration not supported for your OS."
		echo "Automatic updates configuration not supported for your OS."
    fi

    # Ensure fail2ban service is active for brute-force prevention
    sudo systemctl enable --now fail2ban || true
    sudo systemctl restart fail2ban
    log_info "Security hardening complete."
	echo "Security hardening complete."
}


# Harden SSH configuration
harden_ssh_config() {
    log_info "Applying hardened SSH configuration..."
	echo "Applying hardened SSH configuration..."
    
    local SSH_CONFIG="/etc/ssh/sshd_config"
    local TIMESTAMP
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    if [[ ! -f "$SSH_CONFIG" ]]; then
        log_info "SSH configuration file not found; skipping SSH hardening."
		echo "SSH configuration file not found; skipping SSH hardening."
        return 1
    fi

    # Backup current configuration with a timestamp
    sudo cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.${TIMESTAMP}" || {
        log_info "Backup failed; aborting SSH hardening."
		echo "Backup failed; aborting SSH hardening."
        return 1
    }
    
    # Change or insert a value in the config file:
    set_config() {
        local key="$1"
        local value="$2"
        if grep -q "^${key}" "$SSH_CONFIG"; then
            sudo sed -i "s/^#*${key}.*/${key} ${value}/" "$SSH_CONFIG"
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
		echo "SSHD service reloaded successfully."
    else
        log_info "Failed to reload SSH service $SSH_SERVICE."
		echo "Failed to reload SSH service $SSH_SERVICE."
        return 1
    fi

    log_info "Hardened SSH configuration applied."
	echo "Hardened SSH configuration applied."
}


setup_firewall() {
    log_info "Configuring firewall..."
    echo "Configuring firewall..."

    # Extract distribution details.
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        log_warn "Cannot detect operating system; /etc/os-release not found."
        echo "Cannot detect operating system; /etc/os-release not found."
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
                    echo "Unsupported distribution ($ID); cannot determine firewall configuration automatically."
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
                echo "UFW configured successfully on ${ID}."
                sudo ufw status numbered
            else
                log_warn "UFW does not appear to be active. Status: $UFW_STATUS"
                echo "UFW does not appear to be active. Status: $UFW_STATUS"
                return 1
            fi
        else
            log_warn "UFW is not installed on this system."
            echo "UFW is not installed on this system."
            return 1
        fi

    elif [ "$FIREWALL" = "firewalld" ]; then
        if command -v firewall-cmd >/dev/null 2>&1; then

            # --- Check and install python3-nftables on RHEL-based distros ---
            if echo "$ID" | grep -Ei "centos|rocky|almalinux|rhel|fedora" >/dev/null; then
                if ! python3 -c "import nftables" >/dev/null 2>&1; then
                    log_info "python3-nftables is not installed. Attempting installation..."
					echo "python3-nftables is not installed. Attempting installation..."
                    echo "Installing python3-nftables..."
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
                        echo "Warning: Failed to install python3-nftables."
                    else
                        log_info "python3-nftables installed successfully."
                        echo "python3-nftables installed successfully."
                    fi
                fi
            fi
            # --- End of python3-nftables check ---

            # Start firewalld if not already running using systemctl (if available).
            if command -v systemctl >/dev/null 2>&1; then
                FIREWALLD_STATE=$(sudo systemctl is-active firewalld)
                if [ "$FIREWALLD_STATE" != "active" ]; then
                    log_info "firewalld is not active. Starting firewalld..."
                    echo "firewalld is not active. Starting firewalld..."
                    sudo systemctl start firewalld
                    sudo systemctl enable firewalld
                    FIREWALLD_STATUS_LOG=$(sudo systemctl status firewalld | grep "Active:" | head -n1)
                    log_info "firewalld status after start: $FIREWALLD_STATUS_LOG"
                    echo "firewalld status after start: $FIREWALLD_STATUS_LOG"
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
                echo "firewalld reload failed with exit code $RELOAD_STATUS. Please investigate SELinux, dependencies, or configuration."
                return 1
            fi

            log_info "firewalld configured successfully on ${ID}."
            echo "firewalld configured successfully on ${ID}."

            # Verify firewalld state, accepting both "running" and "active" as valid.
            FIREWALLD_STATE=$(sudo firewall-cmd --state 2>/dev/null)
            if [ "$FIREWALLD_STATE" == "running" ] || [ "$FIREWALLD_STATE" == "active" ]; then
                log_info "firewalld is running. Current firewalld settings:"
                echo "firewalld is running. Current firewalld settings:"
                sudo firewall-cmd --list-all
            else
                log_warn "firewalld does not appear to be running. State: $FIREWALLD_STATE"
                echo "firewalld does not appear to be running. State: $FIREWALLD_STATE"
                return 1
            fi
        else
            log_warn "firewall-cmd is not installed on this system."
            echo "firewall-cmd is not installed on this system."
            return 1
        fi
    else
        log_warn "Unsupported firewall configuration: $FIREWALL"
        echo "Unsupported firewall configuration: $FIREWALL"
        return 1
    fi
}






# Setup SSH deployment user if requested.
setup_ssh_deployment() {
    log_info "Setting up SSH deployment environment..."
	echo "Setting up SSH deployment environment..."

    # Install openssh-server using the available package manager.
    if command -v apt-get >/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y openssh-server || { log_error "Failed to install openssh-server via apt-get"; return 1; }
    elif command -v dnf >/dev/null; then
        sudo dnf install -y openssh-server || { log_error "Failed to install openssh-server via dnf"; return 1; }
    elif command -v yum >/dev/null; then
        sudo yum install -y openssh-server || { log_error "Failed to install openssh-server via yum"; return 1; }
    else
        log_error "Unsupported package manager. Please install openssh-server manually."
		echo "Unsupported package manager. Please install openssh-server manually."
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

    if grep -q "^#Port 22" "$ssh_config"; then
        sudo sed -i 's/^#Port 22/Port 2222/' "$ssh_config"
    elif grep -q "^Port 22" "$ssh_config"; then
        sudo sed -i 's/^Port 22/Port 2222/' "$ssh_config"
    else
        echo "Port 2222" | sudo tee -a "$ssh_config" >/dev/null
    fi

    # Restart the SSH service using the proper service name.
    sudo systemctl restart "$ssh_service" || { log_error "Failed to restart SSH service (${ssh_service})"; return 1; }

    log_info "SSH deployment setup complete. SSH now set to listen on port 2222."
	echo "SSH deployment setup complete. SSH now set to listen on port 2222."
}


# Generate Docker Compose file.
generate_docker_compose() {
    log_info "Generating Docker Compose file..."
	echo "Generating Docker Compose file..."
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
    - name: Update and upgrade apt packages
      apt: update_cache=yes upgrade=dist
    - name: Install essential packages
      apt: name={{ item }} state=present
      loop:
        - php
        - apache2
        - mysql-server
EOF
    log_info "Ansible playbook generated: site.yml"
}


# -----------------------------------------------------------------------------
# Function: Enable Apache Modules
# -----------------------------------------------------------------------------
enable_apache_module() {
  local module="$1"
  if [ -f /etc/redhat-release ]; then
    echo "RHEL-based system detected; restarting Apache using httpd..."
    sudo systemctl restart httpd
  else
    echo "Debian-based system detected; enabling module ${module} with a2enmod..."
    sudo a2enmod "$module"
    sudo systemctl reload apache2
  fi
}

install_phpmyadmin() {
  # Ensure we're sourcing OS release information
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    echo "Error: /etc/os-release not found. Cannot determine the OS."
    return 1
  fi

  # Normalize the ID for consistency (if needed)
  distro_id=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

  echo "Detected OS: $PRETTY_NAME"

  case "$distro_id" in
    ubuntu|debian)
      echo "Updating package lists..."
      sudo apt-get update -y
      
      echo "Installing phpMyAdmin..."
      # Use DEBIAN_FRONTEND=noninteractive to avoid interactive prompts
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin
      ;;

    centos|rocky|almalinux|rhel)
      # For RHEL-based distributions, ensure that the EPEL repository is available
      if ! rpm -qa | grep -qw epel-release; then
        echo "EPEL repository not found. Installing epel-release..."
        sudo yum install -y epel-release
      fi

      echo "Installing phpMyAdmin..."
      # Note: Using 'yum' is valid on these systems (or 'dnf' if available)
      sudo yum install -y phpMyAdmin
      ;;

    fedora)
      echo "Installing phpMyAdmin..."
      # Fedora typically uses dnf
      sudo dnf install -y phpMyAdmin
      ;;

    *)
      echo "Unsupported distribution: $distro_id"
	  log_info "Unsupported distribution: $distro_id"
      return 1
      ;;
  esac

  echo "phpMyAdmin installation completed successfully."
  log_info "phpMyAdmin installation completed successfully."
}


# Upgrade system and reconfigure services.
upgrade_system() {
    log_info "Upgrading system and reconfiguring services..."
    pkg_update
    if [[ "${INSTALL_TYPE}" == "standard" ]]; then
        install_standard
    else
        install_lamp
    fi
}

# Uninstall components
uninstall_components() {
    log_info "Preparing to uninstall components..."

    # List of packages includes for removal. Note the lower-case "phpmyadmin"
    local PACKAGES_TO_REMOVE=( \
        "apache2" "apache2-utils" "nginx" "caddy" "lighttpd" \
        "mysql-server" "mariadb-server" "percona-server-server" "postgresql" \
        "php*" "phpmyadmin" \
        "certbot" "${FIREWALL}" "vsftpd" "unattended-upgrades" "fail2ban" \
        "redis-server" "rabbitmq-server" \
    )

    # For RPM-based systems (CentOS, RHEL, Rocky Linux, AlmaLinux), phpMyAdmin may be installed with different case.
    if [[ "$DISTRO" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
        PACKAGES_TO_REMOVE+=( "phpMyAdmin" )
    fi

    log_info "Packages to be removed: ${PACKAGES_TO_REMOVE[*]}"

    # List of directories for removal
    local DIRS_TO_REMOVE=( \
        "/etc/apache2" "/etc/nginx" "/etc/caddy" "${DOC_ROOT}" "/etc/php" \
        "/etc/mysql" "/etc/postgresql" "/etc/letsencrypt" "/etc/fail2ban" \
        "/etc/phpmyadmin" "/etc/phpMyAdmin" "/usr/share/phpmyadmin" "/usr/share/phpMyAdmin" \
        "docker-compose.yml" "site.yml" \
    )
    # Additional directories for RPM-based distributions (CentOS, RHEL, Rocky Linux, AlmaLinux)
    if [[ "$DISTRO" =~ ^(centos|rhel|rocky|almalinux)$ ]]; then
        DIRS_TO_REMOVE+=( "/var/lib/mysql" "/etc/my.cnf" "/etc/my.cnf.d" )
    fi

    echo "WARNING: The following packages and directories will be removed:"
    for item in "${PACKAGES_TO_REMOVE[@]}" "${DIRS_TO_REMOVE[@]}"; do
        echo "   - $item"
    done

    read -rp "Are you sure you want to proceed? This action cannot be reversed! (y/N): " confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log_info "Uninstallation aborted by user."
        exit 0
    fi

    log_info "Stopping services..."
    for service in apache2 nginx caddy lighttpd mysql mariadb postgresql mongod; do
        sudo systemctl stop "$service" 2>/dev/null || true
    done

    log_info "Removing packages..."
    for pkg in "${PACKAGES_TO_REMOVE[@]}"; do
        remove_if_installed "$pkg"
    done

    log_info "Cleaning up directories..."
    for item in "${DIRS_TO_REMOVE[@]}"; do
        sudo rm -rf "$item"
    done

    if [[ "$FIREWALL" == "ufw" && $(command -v ufw) ]]; then
        sudo ufw disable || true
    else
        sudo systemctl stop firewalld || true
        sudo systemctl disable firewalld || true
    fi

    if is_debian; then
        sudo apt-get autoremove -y && sudo apt-get autoclean
    else
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf autoremove -y
        else
            sudo yum autoremove -y
        fi
    fi
    log_info "Uninstallation complete."
}



##############################
# Installation Modes
##############################

install_standard() {
    log_info "Starting Standard LAMP installation (Apache, MariaDB, PHP, phpMyAdmin)..."
    install_prerequisites
    prepare_docroot
    install_php
    install_database
    install_web_server
    setup_virtual_hosts
    install_phpmyadmin
    optimize_performance
    setup_firewall
    security_harden
    setup_ssh_deployment
    if [[ "${WEB_SERVER}" == "Apache" ]]; then
        log_info "Restarting Apache..."
        sudo systemctl restart "$APACHE_PACKAGE"
        sudo systemctl status "$APACHE_PACKAGE"
    fi
    log_info "✅ Standard LAMP installation is complete!"
    echo "Detailed log file saved at: ${LOGFILE}"
}

install_lamp() {
    install_prerequisites
    prepare_docroot
    install_php
    install_database
    install_ftp_sftp
    install_cache
    install_messaging_queue
    install_web_server
    setup_virtual_hosts
    optimize_performance
    setup_firewall
    security_harden
    setup_ssh_deployment
    if [[ "${GENERATE_DOCKER:-false}" == true ]]; then
        generate_docker_compose
    fi
    if [[ "${GENERATE_ANSIBLE:-false}" == true ]]; then
        generate_ansible_playbook
    fi
}

install_prerequisites() {
    pkg_update
    if is_debian; then
        pkg_install software-properties-common openssh-server ufw fail2ban
    else
        pkg_install openssh-server firewalld fail2ban
        if ! rpm -q epel-release >/dev/null 2>&1; then
            pkg_install epel-release
        fi
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

    if is_debian; then
        APACHE_PACKAGE="apache2"
        APACHE_UTILS="apache2-utils"
        REDIS_PACKAGE="redis-server"
        JAVA_PACKAGE="openjdk-11-jdk"
        FIREWALL="ufw"
    else
        APACHE_PACKAGE="httpd"
        APACHE_UTILS=""
        REDIS_PACKAGE="redis"
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

            echo "Installation started at $(date)" > "$LOGFILE"
            exec > >(tee -a "$LOGFILE") 2>&1
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
