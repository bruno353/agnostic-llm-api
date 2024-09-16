#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Por favor, execute como root."
  exit
fi

# ENVs
APP_USER="llmuser"
APP_DIR="/opt/llm-app"
DOMAIN_NAME="llm.techreport.ai"  # Change to your domain
API_KEY="sua_chave_de_api_aqui"  # Change to your api key
EMAIL="blaureanosantos@gmail.com"    # Change to your email
MODEL_NAME="llama3.1:8b"              # Change to your preferable ollama llm

apt update && apt upgrade -y

pip uninstall certbot -y
pip3 uninstall certbot -y
pip uninstall zope.interface -y
pip3 uninstall zope.interface -y
pip uninstall zope.component -y
pip3 uninstall zope.component -y

apt remove --purge certbot -y

apt install -y golang-go nginx snapd curl git

snap install core
snap refresh core
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

curl -O https://ollama.ai/install.sh
chmod +x install.sh
./install.sh

if ! command -v ollama &> /dev/null; then
    echo "Error: Ollama not installed correctly."
    exit 1
fi

ollama pull "$MODEL_NAME"

cat > /etc/systemd/system/ollama.service <<EOL
[Unit]
Description=Ollama Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable ollama.service
systemctl start ollama.service

if systemctl is-active --quiet ollama.service; then
    echo "ollama is running."
else
    echo "Error initiating ollama."
    exit 1
fi

if id "$APP_USER" &>/dev/null; then
    echo "User $APP_USER already exists..."
else
    useradd -m -s /bin/bash "$APP_USER"
fi

if [ -d "$APP_DIR" ]; then
    echo "Dir $APP_DIR already exists..."
else
    mkdir -p "$APP_DIR"
    chown "$APP_USER":"$APP_USER" "$APP_DIR"
fi

if [ -d "$APP_DIR/.git" ]; then
    echo "Repo already cloned $APP_DIR, updating it..."
    su - "$APP_USER" -c "
        cd $APP_DIR
        git pull
    "
else
    su - "$APP_USER" -c "
        git clone https://github.com/bruno353/agnostic-llm-api.git $APP_DIR
    "
fi

su - "$APP_USER" -c "
    cd $APP_DIR
    git fetch origin
    git reset --hard origin/main
"

su - "$APP_USER" -c "
    cd $APP_DIR
    go build -o llm-app
"

cat > /etc/systemd/system/llm-app.service <<EOL
[Unit]
Description=LLM Go Application Service
After=network.target ollama.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/llm-app
Environment=API_KEY=$API_KEY
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable llm-app.service
systemctl start llm-app.service

if command -v ufw >/dev/null 2>&1; then
    ufw allow 'Nginx Full'
fi

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/llm-app.conf
rm -f /etc/nginx/sites-enabled/llm-app.conf

cat > /etc/nginx/sites-available/llm-app.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

ln -s /etc/nginx/sites-available/llm-app.conf /etc/nginx/sites-enabled/

nginx -t && systemctl restart nginx

if systemctl is-active --quiet nginx; then
    echo "Nginx is runnning."
else
    echo "Error starting Nginx."
    exit 1
fi

# Getting SSL cert with certbot
systemctl stop nginx
certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$EMAIL"
systemctl start nginx

# Configure Nginx to use SSL
cat > /etc/nginx/sites-available/llm-app.conf <<EOL
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

nginx -t && systemctl restart nginx

echo "Success setting up server!"
