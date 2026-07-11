#!/bin/bash
################################################################################
# Script for installing Odoo 19 on Ubuntu 24.04 (could be used for other version too)
# Author: Yenthe Van Ginneken
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu because of the different xmlrpc_ports
#-------------------------------------------------------------------------------
# Make a new file:
# sudo nano odoo-install.sh
# Place this content in it and then make the file executable:
# sudo chmod +x odoo-install.sh
# Execute the script to install Odoo:
# ./odoo-install
################################################################################

OE_USER="odoo19"
OE_HOME="/$OE_USER"
OE_HOME_EXT="/opt/$OE_USER"
# The default port where this Odoo instance will run under (provided you use the command -c in the terminal)
# Set to true if you want to install it, false if you don't need it or have it already installed.
INSTALL_WKHTMLTOPDF="True"
# Set the default Odoo port (you still have to use -c /etc/odoo-server.conf for example to use this.)
OE_PORT="8019"
# Choose the Odoo version which you want to install. For example: 16.0, 15.0, 14.0 or saas-22. When using 'master' the master version will be installed.
# IMPORTANT! This script contains extra libraries that are specifically needed for Odoo 17.0
OE_VERSION="19.0"
# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"
# Installs postgreSQL V16 instead of defaults (e.g V12 for Ubuntu 20/22) - this improves performance
INSTALL_POSTGRESQL_SIXTEEN="True"
# Set this to True if you want to install Nginx!
INSTALL_NGINX="True"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN="admin"
# Set to "True" to generate a random password, "False" to use the variable in OE_SUPERADMIN
GENERATE_RANDOM_PASSWORD="False"
OE_CONFIG="${OE_USER}"
# Set the website name
WEBSITE_NAME="_"
# Set the default Odoo longpolling port (you still have to use -c /etc/odoo-server.conf for example to use this.)
LONGPOLLING_PORT="8072"
# Set to "True" to install certbot and have ssl enabled, "False" to use http
ENABLE_SSL="False"
# Provide Email to register ssl certificate
ADMIN_EMAIL="kayondoabdulatif@gmail.com"

# Helper: pip install with optional --break-system-packages (Ubuntu 24.04 / PEP 668)
pip_install() {
  # If venv exists, use venv's pip
  if [ -f "$OE_HOME_EXT/venv/bin/pip3" ]; then
    sudo -H "$OE_HOME_EXT/venv/bin/pip3" install "$@"
  elif pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    sudo -H pip3 install --break-system-packages "$@"
  else
    sudo -H pip3 install "$@"
  fi
}
##

## ### WKHTMLTOPDF download & arch detection (x86/x86_64/ARM) ##
# Installed from the Ubuntu 24.04 repositories

detect_arch() {
  local arch_raw
  arch_raw="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  case "$arch_raw" in
    amd64|x86_64)   ARCH_DEB="amd64";;
    i386|i686)      ARCH_DEB="i386";;
    arm64|aarch64)  ARCH_DEB="arm64";;
    armhf|armv7l)   ARCH_DEB="armhf";;
    *)              ARCH_DEB="$arch_raw";;
  esac

  UBUNTU_CODENAME="$(lsb_release -c -s 2>/dev/null || echo noble)"
  UBUNTU_RELEASE="$(lsb_release -r -s 2>/dev/null || echo 24.04)"
}

install_wkhtmltopdf_from_ubuntu() {
  sudo apt-get update -y
  if sudo apt-get install -y wkhtmltopdf; then
    echo "wkhtmltopdf installed from Ubuntu repositories ($ARCH_DEB)."
    return 0
  fi
  return 1
}

wkhtml_create_symlinks_if_needed() {
  # symlinks
  if [ -x /usr/local/bin/wkhtmltopdf ] && ! command -v wkhtmltopdf >/dev/null 2>&1; then
    sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin || true
  fi
  if [ -x /usr/local/bin/wkhtmltoimage ] && ! command -v wkhtmltoimage >/dev/null 2>&1; then
    sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin || true
  fi
}

detect_arch

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
# universe package is for Ubuntu 18.x
# sudo add-apt-repository universe
# libpng12-0 dependency for wkhtmltopdf for older Ubuntu versions
# sudo add-apt-repository "deb http://mirrors.kernel.org/ubuntu/ xenial main"
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y libpq-dev

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing postgreSQL V16 due to the user it's choise ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update -y
    sudo apt-get install -y postgresql-16
    if [ "$IS_ENTERPRISE" = "True" ]; then
      # Ensure PostgreSQL is running before pgvector setup (Ubuntu 24.04 uses systemd)
      sudo systemctl start postgresql || true
      # pgvector is only needed for Enterprise AI features
      sudo apt-get install -y postgresql-16-pgvector
      # Wait for PostgreSQL to become available
      until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done
      # Create vector extension using a heredoc to avoid any quoting issues
      sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
    fi
else
    echo -e "\n---- Installing the default postgreSQL version based on Linux version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi

echo -e "\n---- Creating the ODOO PostgreSQL User  ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true
sudo su - postgres -c "psql -c \"ALTER USER $OE_USER WITH PASSWORD '$OE_USER';\"" 2> /dev/null || true

#--------------------------------------------------
# Install Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 --"
sudo apt-get install -y python3 python3-pip python3-venv

echo -e "\n---- Create virtual environment ----"
sudo mkdir -p $OE_HOME_EXT
sudo chown $USER:$USER $OE_HOME_EXT
python3 -m venv $OE_HOME_EXT/venv
sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/venv

echo -e "\n---- Install python packages/requirements ----"
pip_install --upgrade pip
pip_install --upgrade setuptools wheel
pip_install -r https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt

# Extra: ensure phonenumbers is installed
pip_install phonenumbers

echo -e "\n---- Installing nodeJS NPM and rtlcss for LTR support ----"
sudo apt-get install nodejs npm -y
sudo npm install -g rtlcss

#--------------------------------------------------
# Install Wkhtmltopdf if needed
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Installing wkhtmltopdf (architecture detected: $ARCH_DEB) ----"

  if install_wkhtmltopdf_from_ubuntu; then
    :
  else
    echo -e "\n---- Could not install from the Ubuntu repositories ----."
  fi

  echo -e "\n---- Ensure that the links are in /usr/local/bin ----"
  wkhtml_create_symlinks_if_needed

  if command -v wkhtmltopdf >/dev/null 2>&1; then
    echo -e "\n---- wkhtmltopdf available at: $(command -v wkhtmltopdf) ----"
  else
    echo -e "\n----- WARNING: wkhtmltopdf was not installed. You can install it manually later ----"
  fi
else
  echo -e "\n---- Wkhtmltopdf will not be installed at the user's choice ----"
fi

echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
#The user should also be added to the sudo'ers group.
sudo adduser $OE_USER sudo

echo -e "\n---- Create Log directory ----"
sudo mkdir /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/odoo $OE_HOME_EXT/

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    pip_install psycopg2-binary pdfminer.six
    sudo su $OE_USER -c "mkdir $OE_HOME_EXT/enterprise"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME_EXT/enterprise" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        echo " "
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME_EXT/enterprise" 2>&1)
    done

    echo -e "\n---- Added Enterprise code under $OE_HOME_EXT/enterprise ----"
    echo -e "\n---- Installing Enterprise specific libraries ----"
    pip_install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

echo -e "\n---- Create custom module directory ----"
sudo su $OE_USER -c "mkdir -p $OE_HOME_EXT/custom-addons"

echo -e "\n---- Download community addons ----"
sudo git clone --depth 1 --branch main https://github.com/Kaylat30/community-addons $OE_HOME_EXT/community-addons/

# echo -e "\n---- Download enterprise addons ----"
# sudo git clone --depth 1 --branch main https://github.com/Kaylat30/enterprise-addons $OE_HOME_EXT/enterprise-addons/

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME/*
sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/custom-addons
sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/community-addons
# sudo chown -R $OE_USER:$OE_USER $OE_HOME_EXT/enterprise-addons

echo -e "* Create server config file"


sudo touch /etc/${OE_CONFIG}.conf
echo -e "* Creating server config file"

sudo bash -c "cat <<EOF > /etc/${OE_CONFIG}.conf
[options]
; This is the password that allows database operations:
admin_passwd = admin_passwd
db_host = localhost
db_port = 5432
http_port = ${OE_PORT}
db_user = ${OE_USER}
db_password = ${OE_USER}
addons_path = ${OE_HOME_EXT}/addons,${OE_HOME_EXT}/custom-addons,${OE_HOME_EXT}/community-addons,${OE_HOME_EXT}/community-addons/accountant_community,${OE_HOME_EXT}/community-addons/payroll_community,${OE_HOME_EXT}/community-addons/studio_community,,${OE_HOME_EXT}/community-addons/ai_community
;,${OE_HOME_EXT}/enterprise-addons
default_productivity_apps = True
;logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
workers = 5
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
;proxy_mode = True
;dbfilter = ^%d$
;dbfilter = ^%h$
;list_db = False
EOF"

sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo su root -c "echo '#!/bin/sh' >> $OE_HOME_EXT/start.sh"
sudo su root -c "echo 'sudo -u $OE_USER $OE_HOME_EXT/odoo-bin --config=/etc/${OE_CONFIG}.conf' >> $OE_HOME_EXT/start.sh"
sudo chmod 755 $OE_HOME_EXT/start.sh

#--------------------------------------------------
# Adding ODOO as a systemd service
#--------------------------------------------------

echo -e "* Create systemd service file"
sudo bash -c "cat <<EOF > /etc/systemd/system/${OE_CONFIG}.service
[Unit]
Description=${OE_CONFIG}
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
PermissionsStartOnly=true
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME_EXT}/venv/bin/python3 ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF"

echo -e "* Security Systemd File"
sudo chmod 644 /etc/systemd/system/${OE_CONFIG}.service

echo -e "* Start ODOO on Startup"
sudo systemctl daemon-reload
sudo systemctl enable ${OE_CONFIG}

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
  echo -e "\n---- Installing and setting up Nginx ----"
  sudo apt-get install -y nginx
  cat <<EOF > ~/odoo
server {
  listen 80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF

  sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_NAME
  sudo ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
  sudo rm /etc/nginx/sites-enabled/default
  sudo service nginx reload
  sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"
  echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_NAME"
else
  echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable ssl with certbot
#--------------------------------------------------

if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ]  && [ $WEBSITE_NAME != "_" ];then
  sudo apt-get update -y
  sudo apt-get install -y snapd
  sudo snap install core; snap refresh core
  sudo snap install --classic certbot
  sudo apt-get install python3-certbot-nginx -y
  sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
  sudo service nginx reload
  echo "SSL/HTTPS is enabled!"
else
  echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
  if [ "$ADMIN_EMAIL" = "odoo@example.com" ]; then
      echo "Certbot does not support registering odoo@example.com. You should use real e-mail address."
  fi

  if [ "$WEBSITE_NAME" = "_" ]; then
      echo "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
  fi
fi

echo -e "* Starting Odoo Service"
sudo systemctl start $OE_CONFIG
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_HOME_EXT"
echo "Addons folders: ${OE_HOME_EXT}/addons, ${OE_HOME_EXT}/community-addons, ${OE_HOME_EXT}/custom-addons,${OE_HOME_EXT}/enterprise-addons"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: sudo systemctl start $OE_CONFIG"
echo "Stop Odoo service: sudo systemctl stop $OE_CONFIG"
echo "Restart Odoo service: sudo systemctl restart $OE_CONFIG"
if [ $INSTALL_NGINX = "True" ]; then
  echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
fi
echo "-----------------------------------------------------------"
