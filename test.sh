#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "##########################################################################"
echo "# Enhanced Multi‑Engine Server Installer & Deployment Script"
echo "# Supports Ubuntu, Debian, CentOS, Rocky Linux, AlmaLinux, and RHEL"
echo "#"
echo "# This script installs a flexible stack with options for:"
echo "# • Multiple database engines:"
echo "#     MySQL, MariaDB, PostgreSQL, SQLite, Percona Server, MongoDB, OracleXE"
echo "# • Multiple web servers:"
echo "#     Apache, Nginx, Caddy, Lighttpd"
echo "# • Extended caching:"
echo "#     Redis, Memcached, Varnish"
echo "# • Messaging queues:"
echo "#     RabbitMQ, Kafka"
echo "# • Containerization & automation support:"
echo "#     Docker Compose file generation, Ansible playbook export"
echo "# • SSH Setup Options:"
echo "#     Standard SSH or Hardened SSH (with Protocol 2, key‑only auth, custom ciphers, etc.)"
echo "#"
echo "# IMPORTANT:"
echo "#   - The script verifies that only compatible installation options are chosen:"
echo "#       • OracleXE is not supported automatically."
echo "#       • Varnish caching is only allowed with Nginx."
echo "#   - After installation a log file (\"installer.log\") is created on your Desktop,"
echo "#     or in your home directory if Desktop does not exist."
echo "##########################################################################"

##########################################
# Detect distribution and set constants  #
##########################################
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
else
    echo "Cannot detect operating system. Exiting."
    exit 1
fi

# For RPM–based distros, we’ll be using dnf if available.
case $DISTRO in
    ubuntu|debian)
        FIREWALL="ufw"
        ;;
    centos|rhel|rocky|almalinux)
        FIREWALL="firewalld"
        ;;
    *)
        echo "Unsupported distro: $DISTRO" >&2
        exit 1
        ;;
esac

##########################################
# Package Management Helper Functions    #
##########################################

pkg_update() {
    echo "Updating system..."
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        if command -v apt-fast >/dev/null 2>&1; then
            apt-fast update && apt-fast upgrade -y
        else
            apt-get update && apt-get upgrade -y
        fi
    else
        if command -v dnf >/dev/null 2>&1; then
            dnf update -y
        else
            yum update -y
        fi
    fi
}

pkg_install() {
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        apt-get install -y "$@"
    else
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        else
            yum install -y "$@"
        fi
    fi
}

pkg_remove() {
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        apt-get purge -y "$@"
    else
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y "$@"
        else
            yum remove -y "$@"
        fi
    fi
}

###################################
# Pre‑Installation Functions      #
###################################

update_system() {
    pkg_update
}

install_prerequisites() {
    update_system
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        pkg_install software-properties-common openssh-server ufw fail2ban
    else
        pkg_install openssh-server firewalld fail2ban
        if ! rpm -q epel-release >/dev/null 2>&1; then
            pkg_install epel-release
        fi
    fi
    if [[ "${INSTALL_UTILS:-false}" = true ]]; then
        pkg_install git curl htop zip unzip
    fi
}

################################
# Compatibility Check Function #
################################

check_compatibility() {
    echo "Performing compatibility checks..."
    if [[ "$DB_ENGINE" == "OracleXE" ]]; then
        echo "Error: Oracle XE installation is not supported automatically. Exiting." >&2
        exit 1
    fi
    if [[ "$CACHE_SETUP" == "Varnish" && "$WEB_SERVER" != "Nginx" ]]; then
        echo "Error: Varnish caching is only supported with Nginx in this installer. Exiting." >&2
        exit 1
    fi
    echo "All compatibility checks passed."
}

################################
# Best PHP Version Selection   #
################################

best_php_version() {
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        if apt-cache show php8.2 >/dev/null 2>&1; then
            echo "8.2"
        elif apt-cache show php8.1 >/dev/null 2>&1; then
            echo "8.1"
        elif apt-cache show php8.0 >/dev/null 2>&1; then
            echo "8.0"
        else
            echo "7.4"
        fi
    else
        echo "8.2"
    fi
}

################################
# User Input Prompts           #
################################

# Determine operation if MODE is not set already.
if [[ -z "${MODE:-}" ]]; then
    echo "Choose an operation:"
    select ACTION in "Install" "Upgrade" "Uninstall"; do
        case $ACTION in
            Install ) MODE="install"; break;;
            Upgrade ) MODE="upgrade"; break;;
            Uninstall ) MODE="uninstall"; break;;
        esac
    done
fi

if [[ "$MODE" != "uninstall" ]]; then
    read -s -p "Enter a default password for DB and admin panels: " DB_PASSWORD
    echo
    read -p "Enter domain name(s) (comma-separated): " DOMAINS
    IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
    read -p "Enter document root directory (default: /var/www/html): " DOC_ROOT
    DOC_ROOT=${DOC_ROOT:-/var/www/html}
    
    # Auto-select the best PHP version.
    PHP_VERSION=$(best_php_version)
    echo "Auto-selected best PHP version: $PHP_VERSION"
    
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
    read -p "Enter allowed SSH usernames (space‑separated, leave empty to allow all): " SSH_ALLOWED_USERS
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

    # Run the compatibility checks.
    check_compatibility

    # Setup log file redirection.
    if [[ -d "$HOME/Desktop" ]]; then
         LOGFILE="$HOME/Desktop/installer.log"
    else
         LOGFILE="$HOME/installer.log"
    fi
    echo "Installation started at $(date)" > "$LOGFILE"
    exec > >(tee -a "$LOGFILE") 2>&1
fi

###################################
# Helper and Modular Functions    #
###################################

setup_firewall() {
    echo "Configuring firewall..."
    if [[ "$FIREWALL" == "ufw" ]]; then
        ufw allow OpenSSH
        if [[ "$WEB_SERVER" == "Nginx" || "$WEB_SERVER" == "Caddy" || "$WEB_SERVER" == "Lighttpd" ]]; then
            ufw allow 'Nginx Full' 2>/dev/null || true
            ufw allow 80/tcp
            ufw allow 443/tcp
        else
            ufw allow 'Apache Full'
        fi
        ufw --force enable
    else
        systemctl start firewalld
        systemctl enable firewalld
        if [[ "$USE_HARDENED_SSH" == true ]]; then
            firewall-cmd --permanent --add-port=2222/tcp
        else
            firewall-cmd --permanent --add-service=ssh
        fi
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
    fi
}

######################################
# Installation Functions for Engines #
######################################

install_php() {
    echo "Installing PHP ${PHP_VERSION} and necessary modules..."
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        pkg_install "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip"
        if [[ "$DB_ENGINE" == "SQLite" ]]; then
            pkg_install "php${PHP_VERSION}-sqlite3" sqlite3
        fi
        if [[ "$WEB_SERVER" == "Nginx" || "$WEB_SERVER" == "Caddy" || "$WEB_SERVER" == "Lighttpd" ]]; then
            pkg_install "php${PHP_VERSION}-fpm"
        else
            pkg_install "libapache2-mod-php${PHP_VERSION}"
        fi
    else
        # For CentOS/RHEL-based systems, use the Remi repository.
        if ! rpm -q remi-release >/dev/null 2>&1; then
            pkg_install "https://rpms.remirepo.net/enterprise/remi-release-8.rpm"
        fi
        if command -v dnf >/dev/null 2>&1; then
            dnf module reset php -y
            dnf module enable php:remi-"${PHP_VERSION}" -y
            pkg_install php php-cli php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip
            if [[ "$DB_ENGINE" == "SQLite" ]]; then
                pkg_install php-sqlite3 sqlite
            fi
        else
            yum module reset php -y
            yum module enable php:remi-"${PHP_VERSION}" -y
            pkg_install php php-cli php-mysqlnd php-gd php-curl php-mbstring php-xml php-zip
            if [[ "$DB_ENGINE" == "SQLite" ]]; then
                pkg_install php-sqlite3 sqlite
            fi
        fi
    fi
}

install_database() {
    echo "Installing database engine: $DB_ENGINE"
    # For RedHat–based distros, switch MySQL to MariaDB if needed.
    if [[ "$DB_ENGINE" == "MySQL" && ( "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ) ]]; then
        echo "MySQL is not available by default on $PRETTY_NAME; switching to MariaDB."
        DB_ENGINE="MariaDB"
    fi
    case $DB_ENGINE in
        "MySQL")
            pkg_install mysql-server
            mysql_secure_installation <<EOF

y
$DB_PASSWORD
$DB_PASSWORD
y
y
y
y
EOF
            ;;
        "MariaDB")
            pkg_install mariadb-server
            mysql_secure_installation <<EOF

y
$DB_PASSWORD
$DB_PASSWORD
y
y
y
y
EOF
            ;;
        "PostgreSQL")
            pkg_install postgresql postgresql-contrib
            sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$DB_PASSWORD';"
            ;;
        "SQLite")
            echo "SQLite is already installed with PHP support."
            ;;
        "Percona")
            pkg_install percona-server-server
            mysql_secure_installation <<EOF

y
$DB_PASSWORD
$DB_PASSWORD
y
y
y
y
EOF
            ;;
        "MongoDB")
            # Use gpg --dearmor to add the MongoDB key.
            wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/mongodb.gpg >/dev/null
            echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -sc)/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list
            update_system
            pkg_install mongodb-org
            systemctl start mongod && systemctl enable mongod
            ;;
        "OracleXE")
            echo "Oracle XE installation requires manual steps. Please refer to Oracle documentation."
            ;;
    esac
}

install_ftp_sftp() {
    if [[ "${INSTALL_FTP:-false}" = true ]]; then
        pkg_install vsftpd
    fi
}

install_cache() {
    case $CACHE_SETUP in
        "Redis")
            pkg_install redis-server
            ;;
        "Memcached")
            pkg_install memcached "php${PHP_VERSION}-memcached"
            ;;
        "Varnish")
            pkg_install varnish
            ;;
        "None")
            echo "No caching system selected."
            ;;
    esac
}

install_messaging_queue() {
    case $MSG_QUEUE in
        "RabbitMQ")
            pkg_install rabbitmq-server
            ;;
        "Kafka")
            pkg_install openjdk-11-jdk
            KAFKA_VERSION="2.8.1"
            KAFKA_SCALA="2.13"
            wget "https://downloads.apache.org/kafka/2.8.1/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" -O /tmp/kafka.tgz
            tar -xzf /tmp/kafka.tgz -C /opt
            mv /opt/kafka_${KAFKA_SCALA}-${KAFKA_VERSION} /opt/kafka
            ;;
        "None")
            echo "No messaging queue selected."
            ;;
    esac
}

############################################
# Install Web Server & Virtual Host Setup  #
############################################

install_web_server() {
    case $WEB_SERVER in
        "Nginx")
            pkg_install nginx
            ;;
        "Apache")
            pkg_install apache2 apache2-utils
            ;;
        "Caddy")
            if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
                pkg_install debian-keyring debian-archive-keyring apt-transport-https
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | tee /etc/apt/trusted.gpg.d/caddy-stable.asc
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
                update_system
                pkg_install caddy
            else
                echo "Caddy installation on $PRETTY_NAME may require manual intervention."
            fi
            ;;
        "Lighttpd")
            pkg_install lighttpd
            ;;
    esac
}

setup_virtual_hosts() {
    echo "Setting up virtual hosts..."
    if [[ "$WEB_SERVER" == "Nginx" || "$WEB_SERVER" == "Apache" ]]; then
        for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
            DOMAIN=$(echo "$DOMAIN" | xargs)
            mkdir -p "$DOC_ROOT/$DOMAIN"
            if [[ "$WEB_SERVER" == "Nginx" ]]; then
                cat <<EOF > /etc/nginx/sites-available/"$DOMAIN"
server {
    listen 80;
    server_name $DOMAIN;
    root $DOC_ROOT/$DOMAIN;
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
                ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/
            else
                cat <<EOF > /etc/apache2/sites-available/"$DOMAIN".conf
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $DOC_ROOT/$DOMAIN
    <Directory $DOC_ROOT/$DOMAIN>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF
                a2ensite "$DOMAIN".conf
            fi
        done
        if [[ "$WEB_SERVER" == "Nginx" ]]; then
            systemctl reload nginx
        else
            a2dissite 000-default
            systemctl reload apache2
        fi
        echo "Installing Certbot and obtaining SSL certificates..."
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            pkg_install certbot "python3-certbot-$([[ "$WEB_SERVER" == "Nginx" ]] && echo "nginx" || echo "apache")"
        else
            pkg_install certbot
        fi
        certbot --$WEB_SERVER -d "${DOMAIN_ARRAY[@]}" --non-interactive --agree-tos -m "admin@$(echo "${DOMAIN_ARRAY[0]}" | xargs)" --redirect
    elif [[ "$WEB_SERVER" == "Caddy" ]]; then
        echo "Configuring Caddy using Caddyfile..."
        cat <<EOF > /etc/caddy/Caddyfile
{
    auto_https off
}
$(for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
    DOMAIN=$(echo "$DOMAIN" | xargs)
    echo "$DOMAIN {"
    echo "    root * $DOC_ROOT/$DOMAIN"
    echo "    file_server"
    echo "    php_fastcgi unix//run/php/php${PHP_VERSION}-fpm.sock"
    echo "}"
done)
EOF
        systemctl reload caddy
    elif [[ "$WEB_SERVER" == "Lighttpd" ]]; then
        echo "Configuring Lighttpd..."
        for DOMAIN in "${DOMAIN_ARRAY[@]}"; do
            DOMAIN=$(echo "$DOMAIN" | xargs)
            mkdir -p "$DOC_ROOT/$DOMAIN"
        done
        lighty-enable-mod fastcgi
        lighty-enable-mod fastcgi-php
        systemctl reload lighttpd
    fi
}

#############################
# Performance Optimizations #
#############################

optimize_performance() {
    echo "Optimizing system performance..."
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -f "$PHP_INI" ]]; then
        cp "$PHP_INI" "${PHP_INI}.bak"
        sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI"
        sed -i 's/display_errors = On/display_errors = Off/' "$PHP_INI"
        if ! grep -q "opcache.enable" "$PHP_INI"; then
            cat <<EOF >> "$PHP_INI"

; OPcache settings for production
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
EOF
        fi
    fi
    if [[ "$WEB_SERVER" == "Nginx" ]]; then
        sed -i '/listen 80;/a listen 443 ssl http2;' /etc/nginx/sites-available/"${DOMAIN_ARRAY[0]}"
        if ! grep -q "gzip on;" /etc/nginx/nginx.conf; then
            sed -i 's/http {*/http { \ngzip on;\ngzip_vary on;\ngzip_proxied any;\ngzip_comp_level 6;\ngzip_min_length 256;\ngzip_types text\/plain application\/xml application\/javascript text\/css;/' /etc/nginx/nginx.conf
        fi
        systemctl reload nginx
    elif [[ "$WEB_SERVER" == "Apache" ]]; then
        a2enmod http2 deflate
        sed -i 's/Protocols h2 http\/1.1/Protocols h2 http\/1.1/' /etc/apache2/apache2.conf
        systemctl restart apache2
    fi
    if [[ "$DB_ENGINE" == "MySQL" || "$DB_ENGINE" == "MariaDB" || "$DB_ENGINE" == "Percona" ]]; then
        grep -q "innodb_buffer_pool_size" /etc/mysql/my.cnf || cat <<EOF >> /etc/mysql/my.cnf

[mysqld]
innodb_buffer_pool_size=256M
max_connections=150
thread_cache_size=50
EOF
        systemctl restart mysql 2>/dev/null || systemctl restart mariadb
    elif [[ "$DB_ENGINE" == "PostgreSQL" ]]; then
        PG_CONF="/etc/postgresql/$(ls /etc/postgresql)/main/postgresql.conf"
        sed -i "s/#shared_buffers = 128MB/shared_buffers = 256MB/" "$PG_CONF"
        sed -i "s/#effective_cache_size = 4GB/effective_cache_size = 2GB/" "$PG_CONF"
        systemctl restart postgresql
    fi
}

########################################
# Security Hardening & SSH Configuration
########################################

security_harden() {
    echo "Starting security hardening procedures..."
    PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
    if [[ -f "$PHP_INI" ]]; then
        cp "$PHP_INI" "${PHP_INI}.sec.bak"
        sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI"
        sed -i 's/display_errors = On/display_errors = Off/' "$PHP_INI"
        if ! grep -q "disable_functions" "$PHP_INI"; then
            echo "disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source" >> "$PHP_INI"
        fi
    fi
    if [[ "$USE_HARDENED_SSH" == true ]]; then
        harden_ssh_config
    else
        echo "Standard SSH configuration applied. No extra hardening."
    fi
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        cat <<EOF >/etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true

[apache-auth]
enabled = true

[nginx-http-auth]
enabled = true

[mysqld]
enabled = true
EOF
    fi
    pkg_install unattended-upgrades
    dpkg-reconfigure -plow unattended-upgrades || true
    systemctl restart fail2ban
    echo "Security hardening complete."
}

harden_ssh_config() {
    echo "Applying hardened SSH configuration..."
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.sshhardening.bak
        if ! grep -q "^Protocol" /etc/ssh/sshd_config; then
            echo "Protocol 2" >> /etc/ssh/sshd_config
        else
            sed -i 's/^Protocol.*/Protocol 2/' /etc/ssh/sshd_config
        fi
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#*Port.*/Port 2222/' /etc/ssh/sshd_config
        sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
        sed -i 's/^#*AllowAgentForwarding.*/AllowAgentForwarding no/' /etc/ssh/sshd_config
        sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
        sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
        sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config
        sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/' /etc/ssh/sshd_config
        if ! grep -q "^Ciphers" /etc/ssh/sshd_config; then
            echo "Ciphers aes256-ctr,aes192-ctr,aes128-ctr" >> /etc/ssh/sshd_config
        fi
        if ! grep -q "^MACs" /etc/ssh/sshd_config; then
            echo "MACs hmac-sha2-512,hmac-sha2-256" >> /etc/ssh/sshd_config
        fi
        if ! grep -q "^KexAlgorithms" /etc/ssh/sshd_config; then
            echo "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" >> /etc/ssh/sshd_config
        fi
        if [[ -n "${SSH_ALLOWED_USERS:-}" ]]; then
            sed -i "s/^#*AllowUsers.*/AllowUsers $SSH_ALLOWED_USERS/" /etc/ssh/sshd_config
        fi
        systemctl reload sshd
        echo "Hardened SSH configuration applied."
    else
        echo "SSH configuration file not found; skipping SSH hardening."
    fi
}

setup_ssh_deployment() {
    echo "Setting up SSH deployment environment..."
    pkg_install openssh-server
    if [[ "${SETUP_SSH_DEPLOY:-false}" == true ]]; then
        read -p "Enter deployment username (default: deploy): " DEPLOY_USER
        DEPLOY_USER=${DEPLOY_USER:-deploy}
        if id "$DEPLOY_USER" &>/dev/null; then
            echo "User $DEPLOY_USER already exists."
        else
            adduser --disabled-password --gecos "" "$DEPLOY_USER"
            usermod -aG sudo "$DEPLOY_USER"
            echo "Created deployment user $DEPLOY_USER."
        fi
        DEPLOY_AUTH_DIR="/home/$DEPLOY_USER/.ssh"
        mkdir -p "$DEPLOY_AUTH_DIR"
        chmod 700 "$DEPLOY_AUTH_DIR"
        read -p "Enter public SSH key for $DEPLOY_USER (leave blank to skip): " DEPLOY_SSH_KEY
        if [[ -n "$DEPLOY_SSH_KEY" ]]; then
            echo "$DEPLOY_SSH_KEY" > "$DEPLOY_AUTH_DIR/authorized_keys"
            chmod 600 "$DEPLOY_AUTH_DIR/authorized_keys"
            chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_AUTH_DIR"
            echo "SSH key added for $DEPLOY_USER."
        else
            echo "No SSH key provided; skipping key configuration for $DEPLOY_USER."
        fi
    fi
    echo "SSH deployment setup complete. SSH now listens on port 2222."
}

##########################################
# Containerization & Automation Support  #
##########################################

generate_docker_compose() {
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
    case $DB_ENGINE in
        "MySQL"|"MariaDB"|"Percona")
            cat <<EOF >> docker-compose.yml
  db:
    image: mysql:5.7
    environment:
      - MYSQL_ROOT_PASSWORD=$DB_PASSWORD
EOF
            ;;
        "PostgreSQL")
            cat <<EOF >> docker-compose.yml
  db:
    image: postgres:latest
    environment:
      - POSTGRES_PASSWORD=$DB_PASSWORD
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
    if [[ "$CACHE_SETUP" == "Redis" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: redis:latest
EOF
    elif [[ "$CACHE_SETUP" == "Memcached" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: memcached:latest
EOF
    elif [[ "$CACHE_SETUP" == "Varnish" ]]; then
        cat <<EOF >> docker-compose.yml
  cache:
    image: varnish:latest
EOF
    fi
    if [[ "$MSG_QUEUE" == "RabbitMQ" ]]; then
        cat <<EOF >> docker-compose.yml
  mq:
    image: rabbitmq:management
EOF
    elif [[ "$MSG_QUEUE" == "Kafka" ]]; then
        cat <<EOF >> docker-compose.yml
  mq:
    image: confluentinc/cp-kafka:latest
EOF
    fi
    echo "Docker Compose file generated: docker-compose.yml"
}

generate_ansible_playbook() {
    echo "Generating Ansible playbook..."
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
    echo "Ansible playbook generated: site.yml"
}

###################################
# Main Installation Routine       #
###################################

install_lamp() {
    install_prerequisites
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

###################################
# Execution Based on Mode         #
###################################

case $MODE in
    install)
        install_lamp
        ;;
    upgrade)
        echo "Upgrading system and reconfiguring services..."
        update_system
        install_lamp
        ;;
    uninstall)
        echo "Uninstalling installed components..."
        systemctl stop apache2 nginx caddy lighttpd mysql mariadb postgresql mongod 2>/dev/null || true
        pkg_remove apache2 apache2-utils nginx caddy lighttpd mysql-server mariadb-server percona-server-server postgresql "php*" certbot "$FIREWALL" vsftpd unattended-upgrades fail2ban redis-server memcached varnish rabbitmq-server
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            apt-get autoremove -y && apt-get autoclean
        elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "rocky" || "$DISTRO" == "almalinux" ]]; then
            if command -v dnf >/dev/null 2>&1; then
                dnf autoremove -y
            else
                yum autoremove -y
            fi
        fi
        rm -rf /etc/apache2 /etc/nginx /etc/caddy "$DOC_ROOT" /etc/php /etc/mysql /etc/postgresql /etc/letsencrypt /etc/fail2ban docker-compose.yml site.yml
        if [[ "$FIREWALL" == "ufw" ]]; then
            ufw disable || true
        else
            systemctl stop firewalld || true
            systemctl disable firewalld || true
        fi
        echo "Components uninstalled."
        ;;
esac

echo "✅ Installation, configuration, and additional engine deployments are complete!"
echo "Detailed log file saved at: $LOGFILE"

# ANSI color array for rainbow
COLORS=(
  '\033[0;31m' # Red
  '\033[0;33m' # Yellow
  '\033[0;32m' # Green
  '\033[0;36m' # Cyan
  '\033[0;34m' # Blue
  '\033[0;35m' # Magenta
)
NC='\033[0m' # Reset color

# ASCII Art for "Lamp by Wulfic"
ART=(
"     ██▓    ▄▄▄       ███▄ ▄███▓ ██▓███      ▄▄▄▄ ▓██   ██▓    █     █░█    ██  ██▓      █████▒██▓ ▄████▄  "
"    ▓██▒   ▒████▄    ▓██▒▀█▀ ██▒▓██░  ██▒   ▓█████▄▒██  ██▒   ▓█░ █ ░█░██  ▓██▒▓██▒    ▓██   ▒▓██▒▒██▀ ▀█  "
"    ▒██░   ▒██  ▀█▄  ▓██    ▓██░▓██░ ██▓▒   ▒██▒ ▄██▒██ ██░   ▒█░ █ ░█▓██  ▒██░▒██░    ▒████ ░▒██▒▒▓█    ▄ "
"    ▒██░   ░██▄▄▄▄██ ▒██    ▒██ ▒██▄█▓▒ ▒   ▒██░█▀  ░ ▐██▓░   ░█░ █ ░█▓▓█  ░██░▒██░    ░▓█▒  ░░██░▒▓▓▄ ▄██▒"
"    ░██████▒▓█   ▓██▒▒██▒   ░██▒▒██▒ ░  ░   ░▓█  ▀█▓░ ██▒▓░   ░░██▒██▓▒▒█████▓ ░██████▒░▒█░   ░██░▒ ▓███▀ ░"
"    ░ ▒░▓  ░▒▒   ▓▒█░░ ▒░   ░  ░▒▓▒░ ░  ░   ░▒▓███▀▒ ██▒▒▒    ░ ▓░▒ ▒ ░▒▓▒ ▒ ▒ ░ ▒░▓  ░ ▒ ░   ░▓  ░ ░▒ ▒  ░"
"    ░ ░ ▒  ░ ▒   ▒▒ ░░  ░      ░░▒ ░        ▒░▒   ░▓██ ░▒░      ▒ ░ ░ ░░▒░ ░ ░ ░ ▒  ░ ░      ▒ ░  ░  ▒  " 
"      ░ ░    ░   ▒   ░      ░   ░░           ░    ░▒ ▒ ░░       ░   ░  ░░░ ░ ░   ░ ░    ░ ░    ▒ ░░      "  
"        ░  ░     ░  ░       ░                ░     ░ ░            ░      ░         ░  ░        ░  ░ ░   "   
"                                              ░░ ░                                            ░        "
"##############################################Lamp by Wulfic################################################"
)

color_index=0
for line in "${ART[@]}"; do
  for (( i=0; i<${#line}; i++ )); do
    char="${line:$i:1}"
    printf "${COLORS[$color_index]}%s" "$char"
    ((color_index=(color_index+1)%${#COLORS[@]}))
  done
  echo -e "${NC}"
done
