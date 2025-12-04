#!/bin/bash

# ==========================================
# MATRIX SYNAPSE + COTURN INSTALLER (V2)
# Tested on Ubuntu 22.04 / Debian 11+
# ==========================================

# --- НАСТРОЙКИ ПОЛЬЗОВАТЕЛЯ (РЕДАКТИРОВАТЬ ЗДЕСЬ) ---
DOMAIN="example.com"                 # Ваш домен (без https://)
EMAIL="admin@example.com"            # Почта для SSL
DB_PASS="StrongPass_$(openssl rand -hex 4)" # Пароль для БД (можно оставить авто-генерацию)

# Белый список доменов для федерации.
# Если хотите общаться со всеми - оставьте скобки пустыми: WHITELIST_DOMAINS=()
# Если только с cupsup.xyz - впишите: WHITELIST_DOMAINS=("abc.xyz")
# WHITELIST_DOMAINS=("abc.xyz")

# ==========================================
# ДАЛЕЕ АВТОМАТИКА (НЕ ТРОГАТЬ)
# ==========================================

# 1. Генерация ключей
REG_SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
TURN_SECRET=$(openssl rand -base64 32)

echo ">>> НАЧАЛО УСТАНОВКИ ДЛЯ: $DOMAIN"
echo ">>> БД ПАРОЛЬ: $DB_PASS"

# 2. Подготовка системы
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl wget lsb-release gnupg2 ufw apt-transport-https ca-certificates

# 3. Настройка Firewall
echo ">>> Настройка Firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8448/tcp
ufw allow 3478/tcp
ufw allow 3478/udp
ufw allow 5349/tcp
ufw allow 5349/udp
ufw allow 49152:65535/udp
ufw --force enable

# 4. Nginx & Certbot
echo ">>> Установка Nginx..."
apt install -y nginx certbot python3-certbot-nginx

# Временный конфиг для получения сертификата
cat > /etc/nginx/sites-available/matrix <<EOF
server {
    server_name $DOMAIN;
    listen 80;
    listen [::]:80;
    return 301 https://\$host\$request_uri;
}
EOF
ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl reload nginx

# Получение сертификата
echo ">>> Получение SSL сертификата..."
certbot certonly --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# Финальный конфиг Nginx
cat > /etc/nginx/sites-available/matrix <<EOF
server {
    server_name $DOMAIN;
    listen 80;
    listen [::]:80;
    return 301 https://\$host\$request_uri;
}

server {
    server_name $DOMAIN;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    listen 8448 ssl;
    listen [::]:8448 ssl;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location /.well-known/matrix/client {
        add_header Content-Type application/json;
        return 200 '{"m.homeserver": {"base_url": "https://$DOMAIN"}}';
    }
    location /.well-known/matrix/server {
        add_header Content-Type application/json;
        return 200 '{"m.server": "$DOMAIN:443"}';
    }

    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://localhost:8008;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
    }
}
EOF
systemctl reload nginx

# 5. PostgreSQL
echo ">>> Установка PostgreSQL..."
apt install -y postgresql postgresql-contrib
# Создание БД (игнорируем ошибку, если уже есть)
sudo -u postgres psql -c "CREATE USER synapse WITH PASSWORD '$DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE synapse OWNER synapse;" || true
sudo -u postgres psql -c "ALTER USER synapse CREATEDB;" || true

# 6. Matrix Synapse
echo ">>> Установка Matrix Synapse..."
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
apt update
# Предустановка ответов для инсталлятора
echo "matrix-synapse-py3 matrix-synapse/server-name string $DOMAIN" | debconf-set-selections
echo "matrix-synapse-py3 matrix-synapse/report-stats boolean false" | debconf-set-selections
apt install -y matrix-synapse-py3

# 7. Настройка Synapse (homeserver.yaml)
CONFIG_FILE="/etc/matrix-synapse/homeserver.yaml"

# Отключаем дефолтную sqlite базу (комментируем строки)
sed -i 's/^database:/#database:/' $CONFIG_FILE
sed -i 's/^  name: sqlite3/#  name: sqlite3/' $CONFIG_FILE
sed -i 's/^  args:/#  args:/' $CONFIG_FILE
sed -i 's/^    database: \/var\/lib/#    database: \/var\/lib/' $CONFIG_FILE

# Добавляем нашу конфигурацию в конец файла
cat >> $CONFIG_FILE <<EOF

# --- AUTO CONFIG V2 ---
# Включаем регистрацию через API (для админ-скрипта)
enable_registration: false
enable_registration_without_verification: true
registration_shared_secret: "$REG_SECRET"

# Настройка базы данных Postgres
database:
  name: psycopg2
  args:
    user: synapse
    password: "$DB_PASS"
    database: synapse
    host: localhost
    cp_min: 5
    cp_max: 10
  allow_unsafe_locale: true

# Настройка TURN (Звонки)
turn_shared_secret: "$TURN_SECRET"
turn_uris: ["turn:$DOMAIN?transport=udp", "turn:$DOMAIN?transport=tcp"]
turn_user_lifetime: 86400000
turn_allow_ip_lifetime: true
EOF

# Добавляем Whitelist, если задан
if [ ${#WHITELIST_DOMAINS[@]} -gt 0 ]; then
    echo "federation_domain_whitelist:" >> $CONFIG_FILE
    for d in "${WHITELIST_DOMAINS[@]}"; do
        echo "  - \"$d\"" >> $CONFIG_FILE
    done
fi

# Перезапуск для применения
systemctl restart matrix-synapse

# 8. Coturn (TURN Server)
echo ">>> Установка Coturn..."
apt install -y coturn

# Полная перезапись конфига
cat > /etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$DOMAIN
cert=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
pkey=/etc/letsencrypt/live/$DOMAIN/privkey.pem
no-multicast-peers
user-quota=100
total-quota=1200
syslog
no-cli
EOF

# Включаем в /etc/default/coturn
sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
systemctl restart coturn

echo "=================================================="
echo "УСТАНОВКА ЗАВЕРШЕНА!"
echo "=================================================="
echo "1. Ваш домен: $DOMAIN"
echo "2. Создайте первого пользователя командой ниже:"
echo "register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008"
echo ""
echo "При создании пользователя ответьте 'yes' на вопрос Make admin."
echo "=================================================="