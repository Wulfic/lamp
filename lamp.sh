#!/bin/bash

set -e

echo "-------------------------------------------"
echo " LAMP Stack Manager - Ubuntu 24.04"
echo "-------------------------------------------"

# Choose operation
echo "Choose an operation:"
select ACTION in "Install" "Upgrade" "Uninstall"; do
    case $ACTION in
        Install ) MODE="install"; break;;
        Upgrade ) MODE="upgrade"; break;;
        Uninstall ) MODE="uninstall"; break;;
    esac
done

# Prompt for phpMyAdmin/MariaDB username, then password + confirmation, domain, DB engine
if [[ "$MODE" != "uninstall" ]]; then
    read -p "Enter the phpMyAdmin/MariaDB username to create: " PMA_USER

    # Prompt for and confirm password
    while true; do
        read -s -p "Enter a default password for MySQL/MariaDB and phpMyAdmin: " DB_PASSWORD
        echo
        read -s -p "Confirm the password: " DB_PASSWORD_CONFIRM
        echo
        if [[ "$DB_PASSWORD" == "$DB_PASSWORD_CONFIRM" ]]; then
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done

    read -p "Enter your domain name (e.g., example.com): " DOMAIN

    # Choose database engine
    echo "Choose the database engine to install:"
    select db_choice in "MySQL" "MariaDB"; do
        case $db_choice in
            MySQL ) DB_ENGINE="mysql"; break;;
            MariaDB ) DB_ENGINE="mariadb"; break;;
        esac
    done
fi

function setup_firewall() {
    echo "Configuring UFW firewall..."
    apt install -y ufw
    ufw allow OpenSSH
    ufw allow 'Apache Full'
    ufw --force enable
}

function install_lamp() {
    echo "Updating system..."
    apt update
    apt upgrade -y

    echo "Installing SSH server..."
    apt install -y ssh

    echo "Installing Apache..."
    apt install -y apache2 apache2-utils

    echo "Installing PHP, modules & PDO..."
    apt install -y php php-cli php-mysql php-pdo php-gd php-curl php-mbstring php-xml php-zip libapache2-mod-php unzip

    echo "Installing Git & Composer..."
    apt install -y git composer

    echo "Installing JavaScript runtime (Node.js & npm)..."
    apt install -y nodejs npm

    echo "Installing $DB_ENGINE..."
    if [ "$DB_ENGINE" = "mysql" ]; then
        DEBIAN_FRONTEND=noninteractive apt install -y mysql-server
    else
        DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server
    fi

    echo "Securing $DB_ENGINE..."
    mysql_secure_installation <<EOF

y
$DB_PASSWORD
$DB_PASSWORD
y
y
y
y
EOF

    echo "Installing phpMyAdmin..."
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/app-password-confirm password $DB_PASSWORD" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_PASSWORD" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/app-pass password $DB_PASSWORD" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
    apt install -y phpmyadmin

    echo "Enabling Apache modules..."
    a2enmod rewrite ssl

    echo "Creating Apache virtual host for $DOMAIN..."
    cat <<EOF > /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF

    a2ensite $DOMAIN
    a2dissite 000-default
    systemctl reload apache2

    echo "Installing Certbot and SSL certificate..."
    apt install -y certbot python3-certbot-apache
    certbot --apache -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN --redirect

    echo "Restarting Apache..."
    systemctl restart apache2

    echo "Creating phpMyAdmin/MariaDB user '$PMA_USER'..."
    mysql -u root -p"$DB_PASSWORD" <<EOF
CREATE USER '$PMA_USER'@'localhost'
  IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES
  ON *.* TO '$PMA_USER'@'localhost'
  WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    echo "✅ User '$PMA_USER' created and granted full privileges."

    echo "Installing Pusher & PHPMailer via Composer..."
    pushd /var/www/html > /dev/null
      composer require pusher/pusher-php-server phpmailer/phpmailer
    popd > /dev/null

    echo "Installing Pusher JavaScript SDK..."
    pushd /var/www/html > /dev/null
      npm install pusher-js
    popd > /dev/null

    setup_firewall

    echo "-------------------------------------------"
    echo "✅ Installation Complete!"
    echo "🌐 Site: https://$DOMAIN"
    echo "🛠 phpMyAdmin: https://$DOMAIN/phpmyadmin"
    echo "🔐 MySQL root password: '$DB_PASSWORD'"
    echo "-------------------------------------------"
}

function upgrade_lamp() {
    echo "Upgrading packages and reconfiguring services..."
    apt update
    apt upgrade -y
    install_lamp
}

function uninstall_lamp() {
    echo "Uninstalling LAMP stack components..."
    systemctl stop apache2 mysql mariadb 2>/dev/null || true
    apt purge -y apache2 apache2-utils mysql-server mariadb-server phpmyadmin php* certbot ufw ssh nodejs npm git composer
    apt autoremove -y
    apt autoclean

    echo "Removing configs and logs..."
    rm -rf /etc/apache2 /var/www/html /etc/php /etc/mysql /etc/letsencrypt /etc/phpmyadmin /var/lib/mysql

    echo "Disabling UFW..."
    ufw disable || true

    echo "-------------------------------------------"
    echo "🧹 LAMP Stack Uninstalled"
    echo "-------------------------------------------"
}

# Execute mode
case $MODE in
    install)   install_lamp   ;;
    upgrade)   upgrade_lamp   ;;
    uninstall) uninstall_lamp ;;
esac
```
