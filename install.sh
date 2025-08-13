#!/bin/bash
# CtrlPanel Automated Installer
# Version: 1.1.1
# Inspired by Pterodactyl's installer
# Author: joy

set -e

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

echo -e "${CYAN}==============================="
echo -e "   CtrlPanel Automated Setup"
echo -e "===============================${RESET}"

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root.${RESET}"
   exit 1
fi

# Prompt for domain
read -rp "Enter your domain for CtrlPanel (e.g., panel.example.com): " PANEL_DOMAIN
read -rp "Enter MySQL root password: " MYSQL_ROOT_PASS
read -rp "Enter CtrlPanel DB name [ctrlpanel]: " DB_NAME
DB_NAME=${DB_NAME:-ctrlpanel}
read -rp "Enter CtrlPanel DB user [ctrlpaneluser]: " DB_USER
DB_USER=${DB_USER:-ctrlpaneluser}
read -rp "Enter CtrlPanel DB user password: " DB_PASS

echo -e "${YELLOW}Updating system...${RESET}"
apt update -y && apt upgrade -y

echo -e "${YELLOW}Installing dependencies...${RESET}"
apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release

# Add PHP repository
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

# Add Redis repo
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list

# Install MariaDB repo (for Ubuntu 20.04)
if [[ "$(lsb_release -rs)" == "20.04" ]]; then
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
fi

apt update -y

# Install PHP & other dependencies
apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
mariadb-server nginx git redis-server unzip certbot python3-certbot-nginx composer

# Enable Redis
systemctl enable --now redis-server

echo -e "${YELLOW}Setting up database...${RESET}"
mysql -u root -p"$MYSQL_ROOT_PASS" <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
CREATE DATABASE IF NOT EXISTS $DB_NAME;
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Download CtrlPanel
echo -e "${YELLOW}Downloading CtrlPanel...${RESET}"
mkdir -p /var/www/ctrlpanel && cd /var/www/ctrlpanel
git clone https://github.com/Ctrlpanel-gg/panel.git ./

# Install PHP dependencies
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

# Set permissions
chown -R www-data:www-data /var/www/ctrlpanel
chmod -R 755 storage/* bootstrap/cache/

# Create storage symlink
php artisan storage:link

# Configure environment
cp .env.example .env
sed -i "s/APP_URL=.*/APP_URL=https:\/\/$PANEL_DOMAIN/" .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=$DB_NAME/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=$DB_USER/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/" .env

# Generate app key
php artisan key:generate --force

# Run migrations
php artisan migrate --seed --force

# Setup SSL
echo -e "${YELLOW}Setting up SSL with Certbot...${RESET}"
certbot certonly --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos -m admin@"$PANEL_DOMAIN"

# Nginx config
cat >/etc/nginx/sites-available/ctrlpanel.conf <<EOL
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $PANEL_DOMAIN;

    root /var/www/ctrlpanel/public;
    index index.php;

    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;

    client_max_body_size 100m;
    client_body_timeout 120s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -s /etc/nginx/sites-available/ctrlpanel.conf /etc/nginx/sites-enabled/ctrlpanel.conf || true
nginx -t && systemctl restart nginx

# Setup cron
(crontab -l ; echo "* * * * * php /var/www/ctrlpanel/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Setup queue worker
cat >/etc/systemd/system/ctrlpanel.service <<EOL
[Unit]
Description=CtrlPanel Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/ctrlpanel/artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOL

systemctl enable --now ctrlpanel.service

echo -e "${GREEN}=========================================${RESET}"
echo -e "${GREEN}CtrlPanel installation complete!${RESET}"
echo -e "Domain: https://$PANEL_DOMAIN"
echo -e "Database: $DB_NAME"
echo -e "User: $DB_USER"
echo -e "${GREEN}Visit https://$PANEL_DOMAIN/installer to finish setup.${RESET}"
