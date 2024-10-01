#!/bin/bash

if [ "$EUID" -ne 0 ]
  then echo "Por favor, execute como root."
  exit
fi

# ENVs
APP_USER="llmuser"
APP_DIR="/opt/llm-app"
DOMAIN_NAME="llm-app.techreport.ai"  # Change to your domain
API_KEY="sua_chave_de_api_aqui"  # Change to your api key
EMAIL="blaureanosantos@gmail.com"    # Change to your email
HF_TOKEN="seu_token_hf_aqui"  # Adicione esta linha


# Lista de modelos para baixar
MODELS=(
    "qwen2.5:32b"
    "nomic-embed-text:latest"
)

apt update && apt upgrade -y

pip uninstall certbot -y
pip3 uninstall certbot -y
pip uninstall zope.interface -y
pip3 uninstall zope.interface -y
pip uninstall zope.component -y
pip3 uninstall zope.component -y

apt remove --purge certbot -y

apt install -y python3-pip python3-venv nginx snapd curl git

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

# Instalar ffmpeg
apt update && apt install ffmpeg -y

# Instalar Rust (necessário para tiktoken)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env

# Instalar whisper e suas dependências
su - "$APP_USER" -c "
    cd $APP_DIR
    python3 -m venv venv
    source venv/bin/activate
    pip install -U pip setuptools-rust
    pip install -U openai-whisper
    pip install git+https://github.com/m-bain/whisperx.git
    pip install -r requirements.txt
"

cat > /etc/systemd/system/llm-app.service <<EOL
[Unit]
Description=LLM Python Flask Application Service
After=network.target ollama.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/gunicorn -w 4 -b 0.0.0.0:8080 --timeout 6000 app:app
Environment=API_KEY=$API_KEY
Environment=HF_TOKEN=$HF_TOKEN
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

    # Adicione esta linha para aumentar o limite
    client_max_body_size 10M;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
}
EOL

nginx -t && systemctl restart nginx

echo "Success setting up server!"

# Função para baixar um modelo
download_model() {
    local model=$1
    echo "Baixando modelo: $model"
    ollama pull $model
    if [ $? -eq 0 ]; then
        echo "Modelo $model baixado com sucesso."
    else
        echo "Erro ao baixar o modelo $model."
    fi
}

# Baixar modelos
echo "Iniciando o download dos modelos..."
for model in "${MODELS[@]}"; do
    download_model $model
done

# Verificar se todos os modelos foram baixados corretamente
echo "Verificando os modelos baixados..."
all_models_downloaded=true
for model in "${MODELS[@]}"; do
    if ! ollama list | grep -q "$model"; then
        echo "Modelo $model não foi encontrado."
        all_models_downloaded=false
    fi
done

if $all_models_downloaded; then
    echo "Todos os modelos foram baixados com sucesso."
else
    echo "Alguns modelos não foram baixados corretamente. Por favor, verifique manualmente."
fi