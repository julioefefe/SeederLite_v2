#!/bin/bash
# =============================================================================
# instalar_seederlinux.sh - Instalação Completa do SeederLinux Lite
# =============================================================================
# Uso: sudo ./instalar_seederlinux.sh
# =============================================================================

set -e  # Interrompe o script em caso de erro

# Cores
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
AZUL='\033[0;34m'
VERMELHO='\033[0;31m'
SEM_COR='\033[0m'

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${AZUL}➜${SEM_COR} $1"
}

log_ok() {
    echo -e "${VERDE}✓${SEM_COR} $1"
}

log_warn() {
    echo -e "${AMARELO}⚠${SEM_COR} $1"
}

log_error() {
    echo -e "${VERMELHO}✗${SEM_COR} $1"
    exit 1
}

# -----------------------------------------------------------------------------
# Verificação de root
# -----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "Execute como root: sudo ./instalar_seederlinux.sh"
fi

echo -e "${AZUL}========================================${SEM_COR}"
echo -e "${AZUL}  SeederLinux Lite - Instalação         ${SEM_COR}"
echo -e "${AZUL}========================================${SEM_COR}"
echo ""

# -----------------------------------------------------------------------------
# 1. Detectar sistema
# -----------------------------------------------------------------------------
log_info "[1/11] Detectando sistema operacional..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSAO=$VERSION_ID
    CODENAME=$VERSION_CODENAME
else
    log_error "Não foi possível identificar a distribuição."
fi

echo "   Distribuição: $NAME $VERSION"
echo "   Codename: $CODENAME"

# -----------------------------------------------------------------------------
# 2. Configurações padrão
# -----------------------------------------------------------------------------
log_info "[2/11] Definindo configurações..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="/var/www/html/seederlinux"

DB_NAME="seederlinux"
DB_USER="seederlinux"
DB_PASS="seederlinux123"

ADMIN_EMAIL="admin@sistema.local"
ADMIN_PASS="Admin@123"
ADMIN_NAME="Administrador"

echo "   Diretório do projeto: $SCRIPT_DIR"
echo "   Diretório web: $WEB_DIR"
echo "   Banco: $DB_NAME / Usuário: $DB_USER"

# -----------------------------------------------------------------------------
# 3. Instalar dependências do sistema
# -----------------------------------------------------------------------------
log_info "[3/11] Instalando dependências..."

apt update -qq

BASE_PKGS="apache2 postgresql postgresql-client curl git unzip openssl jq rsync"

case $DISTRO in
    ubuntu|linuxmint|zorin|pop)
        if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
            apt install -y software-properties-common
            add-apt-repository -y ppa:ondrej/php
            apt update -qq
        fi
        apt install -y $BASE_PKGS \
            libapache2-mod-php8.1 \
            php8.1 php8.1-cli php8.1-common \
            php8.1-pgsql php8.1-curl php8.1-mbstring \
            php8.1-xml php8.1-json
        ;;
    debian)
        PHP_PACKAGES="php libapache2-mod-php"
        for ext in pgsql curl mbstring xml json; do
            if apt-cache show "php-${ext}" &>/dev/null; then
                PHP_PACKAGES="$PHP_PACKAGES php-${ext}"
            fi
        done
        apt install -y $BASE_PKGS $PHP_PACKAGES
        ;;
    *)
        log_error "Distribuição não suportada: $DISTRO"
        ;;
esac

a2enmod rewrite >/dev/null 2>&1 || true
systemctl restart apache2

log_ok "Dependências instaladas"

# -----------------------------------------------------------------------------
# 4. Iniciar PostgreSQL
# -----------------------------------------------------------------------------
log_info "[4/11] Iniciando PostgreSQL..."

systemctl start postgresql
systemctl enable postgresql >/dev/null 2>&1
sleep 2

if ! systemctl is-active --quiet postgresql; then
    log_error "PostgreSQL não iniciou. Verifique com: systemctl status postgresql"
fi
log_ok "PostgreSQL ativo"

# -----------------------------------------------------------------------------
# 5. Criar usuário e banco de dados
# -----------------------------------------------------------------------------
log_info "[5/11] Criando usuário e banco de dados..."

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\"" 2>/dev/null | grep -q 1; then
    su - postgres -c "psql -c \"CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';\""
    log_ok "Usuário $DB_USER criado"
else
    su - postgres -c "psql -c \"ALTER ROLE $DB_USER WITH PASSWORD '$DB_PASS';\""
    log_ok "Senha do usuário $DB_USER atualizada"
fi

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"" 2>/dev/null | grep -q 1; then
    su - postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER;\""
    log_ok "Banco $DB_NAME criado"
else
    log_ok "Banco $DB_NAME já existe"
fi

su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\""
su - postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\""
su - postgres -c "psql -d $DB_NAME -c \"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;\""

# -----------------------------------------------------------------------------
# 6. Configurar autenticação MD5
# -----------------------------------------------------------------------------
log_info "[6/11] Configurando autenticação MD5..."

PG_HBA=$(su - postgres -c "psql -tAc 'SHOW hba_file;'" 2>/dev/null | tr -d ' ')

if [ -n "$PG_HBA" ] && [ -f "$PG_HBA" ]; then
    cp "$PG_HBA" "${PG_HBA}.bak.$(date +%s)"
    sed -i 's/^local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "$PG_HBA"
    sed -i 's/^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+scram-sha-256/host    all             all             127.0.0.1\/32            md5/' "$PG_HBA"
    sed -i 's/^host\s\+all\s\+all\s\+::1\/128\s\+scram-sha-256/host    all             all             ::1\/128                 md5/' "$PG_HBA"
    systemctl restart postgresql
    sleep 2
    log_ok "Autenticação configurada para MD5"
else
    log_warn "Arquivo pg_hba.conf não encontrado. Verifique manualmente."
fi

# -----------------------------------------------------------------------------
# 7. Testar conexão com o banco
# -----------------------------------------------------------------------------
log_info "[7/11] Testando conexão com o banco..."

if PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; then
    log_ok "Conexão ao banco bem-sucedida"
else
    log_error "Falha na conexão com o banco. Verifique as credenciais e a configuração do PostgreSQL."
fi

# -----------------------------------------------------------------------------
# 8. Copiar arquivos do projeto para o diretório web
# -----------------------------------------------------------------------------
log_info "[8/11] Copiando arquivos do projeto..."

if [ -d "$WEB_DIR" ]; then
    log_warn "Diretório $WEB_DIR já existe. Será sobrescrito (exceto storage)."
    if [ -d "$WEB_DIR/storage" ]; then
        mv "$WEB_DIR/storage" /tmp/seeder_storage_backup
    fi
    rm -rf "$WEB_DIR"
fi

mkdir -p "$WEB_DIR"

# Copia todos os arquivos, preservando a estrutura
rsync -av --exclude='.git' --exclude='node_modules' --exclude='*.zip' \
    --exclude='install.sh' --exclude='instalar_seederlinux.sh' \
    "$SCRIPT_DIR/" "$WEB_DIR/" >/dev/null 2>&1

if [ -d "/tmp/seeder_storage_backup" ]; then
    mv /tmp/seeder_storage_backup "$WEB_DIR/storage"
fi

mkdir -p "$WEB_DIR/storage"

log_ok "Arquivos copiados para $WEB_DIR"

# -----------------------------------------------------------------------------
# 9. Gerar config.php com as credenciais do banco
# -----------------------------------------------------------------------------
log_info "[9/11] Criando configuração do banco..."

# CRIA O DIRETÓRIO api/ ANTES DE ESCREVER O ARQUIVO
mkdir -p "$WEB_DIR/api"

cat > "$WEB_DIR/api/config.php" <<PHPEOF
<?php
function getDBConnection() {
    \$host = 'localhost';
    \$port = '5432';
    \$dbname = '$DB_NAME';
    \$user = '$DB_USER';
    \$password = '$DB_PASS';
    
    try {
        \$dsn = "pgsql:host=\$host;port=\$port;dbname=\$dbname";
        \$pdo = new PDO(
            \$dsn,
            \$user,
            \$password,
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false
            ]
        );
        return \$pdo;
    } catch (PDOException \$e) {
        http_response_code(500);
        echo json_encode(['success' => false, 'message' => 'Erro de conexão com o banco de dados']);
        exit;
    }
}
PHPEOF

log_ok "config.php criado em $WEB_DIR/api/config.php"

# -----------------------------------------------------------------------------
# 10. Executar schema.sql e criar usuário administrador
# -----------------------------------------------------------------------------
log_info "[10/11] Executando schema do banco e criando administrador..."

if [ -f "$WEB_DIR/database/schema.sql" ]; then
    PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -f "$WEB_DIR/database/schema.sql" >/dev/null 2>&1
    log_ok "Schema aplicado"
else
    log_warn "schema.sql não encontrado em $WEB_DIR/database/"
fi

HASH=$(php -r "echo password_hash('$ADMIN_PASS', PASSWORD_BCRYPT);")

PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" <<SQLEOF 2>/dev/null
INSERT INTO users (name, email, password_hash, role, active, created_at)
VALUES ('$ADMIN_NAME', '$ADMIN_EMAIL', '$HASH', 'admin_gap', TRUE, NOW())
ON CONFLICT (email) 
DO UPDATE SET password_hash = '$HASH', role = 'admin_gap', active = TRUE;
SQLEOF

if [ $? -eq 0 ]; then
    log_ok "Usuário administrador criado/atualizado: $ADMIN_EMAIL"
else
    log_warn "Não foi possível criar o administrador. Verifique se a tabela 'users' existe."
fi

# -----------------------------------------------------------------------------
# 11. Configurar Apache
# -----------------------------------------------------------------------------
log_info "[11/11] Configurando Apache..."

cat > /etc/apache2/sites-available/seederlinux.conf <<APACHEEOF
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot $WEB_DIR

    <Directory $WEB_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /api $WEB_DIR/api
    <Directory $WEB_DIR/api>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/seederlinux_error.log
    CustomLog \${APACHE_LOG_DIR}/seederlinux_access.log combined
</VirtualHost>
APACHEEOF

a2dissite 000-default.conf >/dev/null 2>&1 || true
a2ensite seederlinux.conf >/dev/null 2>&1

chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
chmod -R 775 "$WEB_DIR/storage"

systemctl restart apache2

log_ok "Apache configurado"

# -----------------------------------------------------------------------------
# Verificação final (teste da API)
# -----------------------------------------------------------------------------
log_info "Verificando a instalação..."

sleep 2
API_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/organizations 2>/dev/null || echo "000")

if [ "$API_RESPONSE" = "200" ] || [ "$API_RESPONSE" = "401" ] || [ "$API_RESPONSE" = "405" ]; then
    log_ok "API respondeu (HTTP $API_RESPONSE)"
else
    log_warn "A API não respondeu como esperado. Código: $API_RESPONSE"
fi

# -----------------------------------------------------------------------------
# Resumo final
# -----------------------------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${VERDE}========================================${SEM_COR}"
echo -e "${VERDE}  ✅ INSTALAÇÃO CONCLUÍDA!               ${SEM_COR}"
echo -e "${VERDE}========================================${SEM_COR}"
echo ""
echo -e "🌐 Página pública:  ${AZUL}http://$IP/${SEM_COR}"
echo -e "🔐 Painel admin:    ${AZUL}http://$IP/painel/${SEM_COR}"
echo -e "🔌 API:             ${AZUL}http://$IP/api/${SEM_COR}"
echo -e "🗄️  Banco:          ${AZUL}$DB_NAME (usuário: $DB_USER / senha: $DB_PASS)${SEM_COR}"
echo -e "👨‍💼 Administrador:   ${AZUL}$ADMIN_EMAIL / $ADMIN_PASS${SEM_COR}"
echo ""
echo -e "${AMARELO}⚠️  Altere as senhas padrão em produção!${SEM_COR}"
echo -e "📁 Arquivos em:     $WEB_DIR"
echo ""

exit 0
