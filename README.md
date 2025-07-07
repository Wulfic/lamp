#PLEASE RUN

#

#sudo chmod +x lamp.sh

#sudo ./lamp.sh

#

# LAMP Stack Manager

#

#A simple Bash script to install, upgrade, or uninstall a LAMP stack on Ubuntu 24.04.

#

## Features

#

#- Interactive menu to choose between Install, Upgrade, or Uninstall modes  

#

#- Supports selection of MySQL or MariaDB as the database engine  

#

#-Automates installation of:

#

 - Apache and common PHP extensions (gd, curl, mbstring, xml, zip, PDO)

 - Git and Composer

 - Node.js and npm

 - phpMyAdmin with automated DB and Apache configuration

 - SSL certificate provisioning via Certbot

 - UFW firewall configuration for SSH and HTTP/S  

#

#- Runs mysql_secure_installation non-interactively  

#

#- Generates an Apache virtual host for your domain and enables rewrite & SSL modules  

#

#- Creates a phpMyAdmin/MariaDB user with full privileges  

#

#- Installs Pusher (server & JS SDK) and PHPMailer via Composer and npm  

#

### Requirements

#

#- Ubuntu 24.04 server  

#- sudo or root privileges  

#- Internet connection  

#

