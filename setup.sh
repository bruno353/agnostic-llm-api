#!/bin/bash

# Verifica se o script está sendo executado como root
if [ "$EUID" -ne 0 ]
  then echo "Por favor, execute como root."
  exit
fi

# Variáveis de configuração
APP_USER="llmuser"
APP_DIR="/opt/llm-app"
DOMAIN_NAME="llm.techreport.ai"  # Substitua pelo seu domínio
API_KEY="sua_chave_de_api_aqui"  # Substitua pela sua chave de API
EMAIL="blaureanosantos@gmail.com"    # Substitua pelo seu email
MODEL_NAME="gemma2:2b"              # Nome do modelo Ollama a ser baixado

# Atualiza o sistema
apt update && apt upgrade -y

# Remove pacotes conflitantes instalados via pip/pip3
pip uninstall certbot -y
pip3 uninstall certbot -y
pip uninstall zope.interface -y
pip3 uninstall zope.interface -y
pip uninstall zope.component -y
pip3 uninstall zope.component -y

# Remove o Certbot instalado via apt (caso exista)
apt remove --purge certbot -y

# Instala dependências
apt install -y golang-go nginx snapd curl git

# Instala o Certbot via snap
snap install core
snap refresh core
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot

# Instala o Ollama
curl -O https://ollama.ai/install.sh
chmod +x install.sh
./install.sh

# Verifica se o Ollama foi instalado
if ! command -v ollama &> /dev/null; then
    echo "Erro: Ollama não foi instalado corretamente."
    exit 1
fi

# Baixa o modelo necessário para o Ollama
ollama pull "$MODEL_NAME"

# Configura o Ollama como um serviço systemd
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

# Recarrega o systemd e inicia o serviço Ollama
systemctl daemon-reload
systemctl enable ollama.service
systemctl start ollama.service

# Verifica se o Ollama está rodando
if systemctl is-active --quiet ollama.service; then
    echo "Ollama está rodando."
else
    echo "Erro ao iniciar o Ollama. Verifique a configuração."
    exit 1
fi

# Cria um usuário para o aplicativo (ignora se já existir)
if id "$APP_USER" &>/dev/null; then
    echo "Usuário $APP_USER já existe, continuando..."
else
    useradd -m -s /bin/bash "$APP_USER"
fi

# Cria o diretório do aplicativo (ignora se já existir)
if [ -d "$APP_DIR" ]; then
    echo "Diretório $APP_DIR já existe, continuando..."
else
    mkdir -p "$APP_DIR"
    chown "$APP_USER":"$APP_USER" "$APP_DIR"
fi

# Clona o repositório do aplicativo (atualiza se já existir)
if [ -d "$APP_DIR/.git" ]; then
    echo "Repositório já clonado em $APP_DIR, atualizando..."
    su - "$APP_USER" -c "
        cd $APP_DIR
        git pull
    "
else
    su - "$APP_USER" -c "
        git clone https://github.com/bruno353/aws-ec2-cuda-ollama-api.git $APP_DIR
    "
fi

# Atualiza o código do aplicativo (caso tenha modificado o main.go)
su - "$APP_USER" -c "
    cd $APP_DIR
    git fetch origin
    git reset --hard origin/main
"

# Compila o aplicativo Go
su - "$APP_USER" -c "
    cd $APP_DIR
    go build -o llm-app
"

# Configura o serviço systemd para o aplicativo Go
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

# Recarrega o systemd e inicia o serviço do aplicativo Go
systemctl daemon-reload
systemctl enable llm-app.service
systemctl start llm-app.service

# Abre as portas 80 e 443 no firewall (se estiver usando ufw)
if command -v ufw >/dev/null 2>&1; then
    ufw allow 'Nginx Full'
fi

# Remove configurações Nginx existentes para evitar conflitos
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/llm-app.conf
rm -f /etc/nginx/sites-enabled/llm-app.conf

# Cria uma configuração básica do Nginx (sem SSL)
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

# Ativa a configuração do Nginx
ln -s /etc/nginx/sites-available/llm-app.conf /etc/nginx/sites-enabled/

# Testa a configuração do Nginx e reinicia o serviço
nginx -t && systemctl restart nginx

# Verifica se o Nginx está rodando corretamente
if systemctl is-active --quiet nginx; then
    echo "Nginx está rodando."
else
    echo "Erro ao iniciar o Nginx. Verifique a configuração."
    exit 1
fi

# Obtém o certificado SSL com o Certbot em modo standalone
systemctl stop nginx
certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$EMAIL"
systemctl start nginx

# Configura o Nginx para usar SSL
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

# Testa a configuração do Nginx e reinicia o serviço
nginx -t && systemctl restart nginx

echo "Configuração concluída com sucesso!"
