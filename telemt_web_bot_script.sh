#!/bin/bash
# Отключаем set -e в начале, будем обрабатывать ошибки вручную
set +e

# ============================================
# Цвета и оформление
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================
# Конфигурация
# ============================================
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_CONFIG="/etc/telemt/config.toml"
TELEMT_USER="telemt"
TELEMT_GROUP="telemt"
DATA_DIR="/var/lib/telemt"
LOG_DIR="/var/log/telemt"
SERVICE_FILE="/etc/systemd/system/telemt.service"
BOT_DIR="/opt/telemt-bot"
BOT_SERVICE="/etc/systemd/system/telemt-bot.service"
BOT_SCRIPT="$BOT_DIR/bot.py"

# Пути для Web панели
PANEL_INSTALL_SCRIPT="/tmp/telemt-panel-install.sh"
PANEL_CONFIG="/opt/etc/telemt-panel/config.toml"
PANEL_BIN="/opt/bin/telemt/telemt-panel"
PANEL_SERVICE="/etc/systemd/system/telemt-panel.service"
PANEL_NGINX_CONF="/etc/nginx/sites-available/telemt-panel"
PANEL_NGINX_ENABLED="/etc/nginx/sites-enabled/telemt-panel"
PANEL_SSL_KEY="/etc/ssl/private/telemt-panel.key"
PANEL_SSL_CRT="/etc/ssl/certs/telemt-panel.crt"

# ============================================
# Вспомогательные функции
# ============================================
error() { echo -e "${RED}${BOLD}[ОШИБКА]${NC} $1" >&2; }
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "${CYAN}[→]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}[✔]${NC} $1"; }

pause() {
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен выполняться от root (используйте sudo)"
        exit 1
    fi
}

get_server_ip() {
    ipv4=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null)
    if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
    else
        ipv4=$(curl -4 -s ipinfo.io/ip 2>/dev/null)
        if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ipv4"
        else
            echo "IP_НЕ_ОПРЕДЕЛЕН"
        fi
    fi
}

generate_random_hex() {
    openssl rand -hex 16
}

get_users_list() {
    local in_users=0
    while IFS= read -r line; do
        if [[ "$line" == "[access.users]" ]]; then
            in_users=1
            continue
        fi
        if [[ $in_users -eq 1 ]] && [[ "$line" =~ ^\[ ]]; then
            in_users=0
        fi
        if [[ $in_users -eq 1 ]] && [[ "$line" =~ ^[a-zA-Z0-9_-]+\ =\ \"[a-f0-9]{32}\"$ ]]; then
            echo "$line"
        fi
    done < $TELEMT_CONFIG
}

get_users_count() {
    get_users_list | wc -l
}

fix_config_permissions() {
    chown $TELEMT_USER:$TELEMT_GROUP $TELEMT_CONFIG 2>/dev/null
    chmod 644 $TELEMT_CONFIG 2>/dev/null
}

ensure_at_least_one_user() {
    local users_count=$(get_users_count 2>/dev/null || echo 0)
    if [[ $users_count -eq 0 ]]; then
        step "Нет пользователей. Добавляем тестового..."
        local temp_secret=$(openssl rand -hex 16 2>/dev/null)
        if [[ -n "$temp_secret" ]]; then
            if ! grep -q "^\[access.users\]" $TELEMT_CONFIG; then
                echo "" >> $TELEMT_CONFIG
                echo "[access.users]" >> $TELEMT_CONFIG
            fi
            sed -i "/^\[access.users\]/a temp_user = \"$temp_secret\"" $TELEMT_CONFIG
            fix_config_permissions
            info "Добавлен тестовый пользователь: temp_user"
            return 0
        else
            error "Не удалось сгенерировать секрет"
            return 1
        fi
    fi
    return 1
}

# ============================================
# Функции установки и удаления telemt
# ============================================
install_telemt() {
    clear
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}           УСТАНОВКА TELEMT${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    step "Проверка наличия telemt..."
    if [[ -f "$TELEMT_BIN" ]]; then
        warn "Telemt уже установлен"
        read -p "Переустановить? (y/N): " reinstall
        if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
            return
        fi
        step "Остановка старых сервисов..."
        systemctl stop telemt 2>/dev/null
        systemctl disable telemt 2>/dev/null
        step "Удаление старых файлов..."
        rm -f $TELEMT_BIN 2>/dev/null
        rm -rf /etc/telemt /var/lib/telemt /var/log/telemt 2>/dev/null
        rm -f $SERVICE_FILE 2>/dev/null
        systemctl daemon-reload
    fi

    step "Установка системных зависимостей..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y curl git build-essential pkg-config libssl-dev xxd
    elif command -v yum &>/dev/null; then
        yum install -y curl git gcc make openssl-devel vim-common
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm curl git base-devel openssl xxd
    else
        warn "Не удалось определить пакетный менеджер. Установите вручную: curl, git, rust/cargo, xxd"
    fi

    step "Установка Rust (неинтерактивно)..."
    if ! command -v cargo &>/dev/null; then
        info "Скачивание rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh
        info "Установка Rust (это может занять несколько минут)..."
        sh /tmp/rustup.sh -y --default-toolchain stable
        source "$HOME/.cargo/env"
        rm -f /tmp/rustup.sh
        success "Rust установлен"
    else
        info "Rust уже установлен: $(rustc --version 2>/dev/null)"
    fi

    step "Клонирование и сборка telemt..."
    cd /tmp
    rm -rf telemt
    git clone https://github.com/telemt/telemt.git
    cd telemt

    step "Компиляция telemt (это может занять 5-10 минут)..."
    cargo build --release

    step "Создание пользователя и директорий..."
    id -u $TELEMT_USER &>/dev/null || useradd -r -s /bin/false -d $DATA_DIR $TELEMT_USER
    mkdir -p /etc/telemt $DATA_DIR $LOG_DIR
    chown -R $TELEMT_USER:$TELEMT_GROUP /etc/telemt $DATA_DIR $LOG_DIR

    step "Установка бинарного файла..."
    cp target/release/telemt $TELEMT_BIN
    chmod +x $TELEMT_BIN

    step "Создание конфигурации..."
    create_default_config

    step "Создание systemd сервиса..."
    create_systemd_service

    step "Запуск telemt..."
    systemctl daemon-reload
    systemctl enable telemt
    systemctl start telemt

    sleep 3

    if systemctl is-active --quiet telemt; then
        success "Telemt успешно установлен и запущен!"
        echo ""
        echo -e "${CYAN}Порт по умолчанию:${NC} 7443"
        echo -e "${CYAN}SNI по умолчанию:${NC} www.google.com"
        echo -e "${CYAN}Для добавления пользователя выберите пункт 3${NC}"
    else
        warn "Сервис не запустился. Проверьте логи: journalctl -u telemt -n 20"
    fi

    pause
}

create_default_config() {
    temp_secret=$(openssl rand -hex 16)

    cat > $TELEMT_CONFIG << EOF
# === General Settings ===
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 7443

[server.api]
enabled = true
listen = "127.0.0.1:9091"

# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "www.google.com"

[access.users]
temp_user = "$temp_secret"
EOF
    chown $TELEMT_USER:$TELEMT_GROUP $TELEMT_CONFIG
    chmod 644 $TELEMT_CONFIG
}

create_systemd_service() {
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TELEMT_USER
Group=$TELEMT_GROUP
WorkingDirectory=$DATA_DIR
ExecStart=$TELEMT_BIN $TELEMT_CONFIG
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

uninstall_telemt() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ TELEMT${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    warn "ВНИМАНИЕ! Это действие полностью удалит telemt и все данные:"
    echo "  • Бинарный файл: $TELEMT_BIN"
    echo "  • Конфигурация: /etc/telemt"
    echo "  • Данные: $DATA_DIR"
    echo "  • Логи: $LOG_DIR"
    echo "  • Systemd сервис"
    echo ""
    read -p "Вы уверены, что хотите удалить telemt? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi

    step "Остановка сервиса..."
    systemctl stop telemt 2>/dev/null
    systemctl disable telemt 2>/dev/null

    step "Удаление файлов..."
    rm -f $SERVICE_FILE
    rm -f $TELEMT_BIN
    rm -rf /etc/telemt
    rm -rf $DATA_DIR
    rm -rf $LOG_DIR
    rm -rf /tmp/telemt

    step "Обновление systemd..."
    systemctl daemon-reload

    success "Telemt полностью удален"
    pause
}

# ============================================
# Управление пользователями
# ============================================
add_user() {
    clear
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}           ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "www.google.com")
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "7443")

    echo -e "${CYAN}Текущий SNI сервера:${NC} ${YELLOW}$current_sni${NC}"
    echo -e "${CYAN}Текущий порт:${NC} ${YELLOW}$current_port${NC}"
    echo ""

    read -p "Введите имя пользователя (тег): " username

    if ! [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Имя пользователя может содержать только латинские буквы, цифры, - и _"
        pause
        return
    fi

    [[ -z "$username" ]] && username="user_$(date +%s)"

    if grep -q "^$username = " $TELEMT_CONFIG; then
        error "Пользователь с именем '$username' уже существует!"
        pause
        return
    fi

    echo ""
    echo -e "${CYAN}Ограничение по IP:${NC}"
    echo "  Если включить, ссылкой сможет пользоваться только один человек одновременно"
    echo "  (с одного IP-адреса)"
    read -p "Установить лимит 1 IP на пользователя? (y/N): " limit_ip

    secret_random=$(openssl rand -hex 16)
    sni_hex=$(echo -n "$current_sni" | xxd -p -c 1000)
    full_secret="ee${secret_random}${sni_hex}"

    if ! grep -q "^\[access.users\]" $TELEMT_CONFIG; then
        echo "" >> $TELEMT_CONFIG
        echo "[access.users]" >> $TELEMT_CONFIG
    fi

    sed -i "/^\[access.users\]/a $username = \"$secret_random\"" $TELEMT_CONFIG
    fix_config_permissions

    if ! grep -q "^$username = " $TELEMT_CONFIG; then
        error "Не удалось добавить пользователя в конфиг!"
        pause
        return
    fi

    if [[ "$limit_ip" == "y" || "$limit_ip" == "Y" ]]; then
        if ! grep -q "^\[access.user_max_unique_ips\]" $TELEMT_CONFIG; then
            echo "" >> $TELEMT_CONFIG
            echo "[access.user_max_unique_ips]" >> $TELEMT_CONFIG
        fi
        sed -i "/^$username = [0-9]/d" $TELEMT_CONFIG
        echo "$username = 1" >> $TELEMT_CONFIG
        info "Для пользователя $username установлено ограничение: 1 IP"
        fix_config_permissions
    fi

    users_count=$(get_users_count)
    if [[ $users_count -gt 1 ]] && grep -q "^temp_user = " $TELEMT_CONFIG; then
        sed -i "/^temp_user = /d" $TELEMT_CONFIG
        sed -i "/^temp_user = [0-9]/d" $TELEMT_CONFIG
        fix_config_permissions
    fi

    systemctl restart telemt
    sleep 2

    server_ip=$(get_server_ip)
    tg_link="tg://proxy?server=$server_ip&port=$current_port&secret=$full_secret"
    https_link="https://t.me/proxy?server=$server_ip&port=$current_port&secret=$full_secret"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}ПОЛЬЗОВАТЕЛЬ ДОБАВЛЕН!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Имя:${NC} $username"
    echo -e "${YELLOW}Секрет (32 hex):${NC} $secret_random"
    if [[ "$limit_ip" == "y" || "$limit_ip" == "Y" ]]; then
        echo -e "${YELLOW}Ограничение:${NC} ${GREEN}1 IP одновременно${NC}"
    else
        echo -e "${YELLOW}Ограничение:${NC} без ограничений"
    fi
    echo -e "${YELLOW}📱 TG ссылка (нажмите для установки):${NC}"
    echo -e "${GREEN}$tg_link${NC}"
    echo ""
    echo -e "${YELLOW}🌐 HTTP ссылка (для копирования):${NC}"
    echo -e "${GREEN}$https_link${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    pause
}

list_users() {
    clear
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}           СПИСОК ПОЛЬЗОВАТЕЛЕЙ${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "www.google.com")
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "7443")
    server_ip=$(get_server_ip)

    echo -e "${CYAN}Глобальный SNI сервера:${NC} ${YELLOW}$current_sni${NC}"
    echo -e "${CYAN}Порт:${NC} ${YELLOW}$current_port${NC}"
    echo -e "${CYAN}IP сервера:${NC} ${YELLOW}$server_ip${NC}"
    echo ""

    users=$(get_users_list)

    if [[ -z "$users" ]]; then
        warn "Нет добавленных пользователей"
        pause
        return
    fi

    declare -A ip_limits
    while IFS='=' read -r user limit; do
        user=$(echo "$user" | xargs)
        limit=$(echo "$limit" | xargs)
        if [[ -n "$user" && "$limit" =~ ^[0-9]+$ ]]; then
            ip_limits["$user"]="$limit"
        fi
    done < <(sed -n '/^\[access.user_max_unique_ips\]/,/^\[/p' $TELEMT_CONFIG | grep -E '^[a-zA-Z0-9_-]+ = [0-9]+' 2>/dev/null || true)

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${CYAN}%-4s %-20s %-40s %-10s${NC}\n" "№" "ИМЯ" "СЕКРЕТ (32 hex)" "ЛИМИТ IP"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    line_num=1
    while IFS='=' read -r username secret_part; do
        username=$(echo "$username" | xargs)
        secret=$(echo "$secret_part" | xargs | tr -d '"')
        if [[ -n "$username" && "$username" != "#"* ]]; then
            limit="${ip_limits[$username]:-без лимита}"
            if [[ "$limit" == "1" ]]; then
                limit_display="${GREEN}1 IP${NC}"
            else
                limit_display="${YELLOW}$limit${NC}"
            fi

            sni_hex=$(echo -n "$current_sni" | xxd -p -c 1000)
            full_secret="ee${secret}${sni_hex}"
            tg_link="tg://proxy?server=$server_ip&port=$current_port&secret=$full_secret"
            https_link="https://t.me/proxy?server=$server_ip&port=$current_port&secret=$full_secret"

            printf "%-4s %-20s %-40s ${limit_display}\n" "$line_num" "$username" "$secret"
            echo -e "    ${GREEN}📱 TG ссылка:${NC} $tg_link"
            echo -e "    ${BLUE}🌐 HTTP ссылка:${NC} $https_link"
            echo ""
            ((line_num++))
        fi
    done <<< "$users"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "Всего пользователей: $((line_num - 1))"

    pause
}

remove_user() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    users=$(get_users_list)

    if [[ -z "$users" ]]; then
        warn "Нет добавленных пользователей"
        pause
        return
    fi

    echo -e "${CYAN}Существующие пользователи:${NC}"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "${CYAN}%-4s %-20s %-40s${NC}\n" "№" "ИМЯ" "СЕКРЕТ (32 hex)"
    echo "─────────────────────────────────────────────────────────────────────────────"

    line_num=1
    declare -a usernames
    while IFS='=' read -r username secret_part; do
        username=$(echo "$username" | xargs)
        secret=$(echo "$secret_part" | xargs | tr -d '"')
        if [[ -n "$username" && "$username" != "#"* ]]; then
            printf "%-4s %-20s %-40s\n" "$line_num" "$username" "$secret"
            usernames[$line_num]=$username
            ((line_num++))
        fi
    done <<< "$users"
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo ""

    users_count=$((line_num - 1))

    if [[ $users_count -eq 1 ]]; then
        error "Нельзя удалить единственного пользователя! Добавьте хотя бы одного пользователя перед удалением."
        pause
        return
    fi

    read -p "Введите номер пользователя для удаления (1-$users_count): " user_num

    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [[ $user_num -lt 1 ]] || [[ $user_num -ge $line_num ]]; then
        error "Неверный номер"
        pause
        return
    fi

    username_to_remove="${usernames[$user_num]}"

    echo ""
    warn "Вы собираетесь удалить пользователя: ${YELLOW}$username_to_remove${NC}"
    read -p "Подтвердите удаление (y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi

    sed -i "/^$username_to_remove = /d" $TELEMT_CONFIG
    sed -i "/^$username_to_remove = [0-9]/d" $TELEMT_CONFIG
    fix_config_permissions
    systemctl restart telemt
    success "Пользователь $username_to_remove удален"

    pause
}

# ============================================
# Настройка SNI, порта и лимитов
# ============================================
change_sni() {
    clear
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}           СМЕНА SNI${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "www.google.com")
    echo -e "Текущий SNI: ${YELLOW}$current_sni${NC}"
    echo ""

    read -p "Введите новый SNI (например: cloudflare.com, www.google.com): " new_sni

    if [[ -z "$new_sni" ]]; then
        error "SNI не может быть пустым"
        pause
        return
    fi

    step "Обновление конфигурации..."
    sed -i "s/tls_domain = \".*\"/tls_domain = \"$new_sni\"/" $TELEMT_CONFIG

    ensure_at_least_one_user
    fix_config_permissions

    step "Перезапуск сервиса..."
    systemctl restart telemt

    sleep 2

    if systemctl is-active --quiet telemt; then
        success "SNI изменен на $new_sni"
    else
        error "Сервис не запустился. Проверьте логи: journalctl -u telemt -n 20"
    fi

    pause
}

change_port() {
    clear
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}           СМЕНА ПОРТА${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "7443")
    echo -e "Текущий порт: ${YELLOW}$current_port${NC}"
    echo ""

    read -p "Введите новый порт (1-65535, рекомендуется 443 или 8443): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ $new_port -lt 1 ]] || [[ $new_port -gt 65535 ]]; then
        error "Неверный номер порта"
        pause
        return
    fi

    step "Обновление порта в конфигурации..."
    sed -i "s/port = [0-9]*/port = $new_port/" $TELEMT_CONFIG

    ensure_at_least_one_user
    fix_config_permissions

    step "Перезапуск сервиса..."
    systemctl restart telemt

    if systemctl is-active --quiet telemt; then
        success "Порт изменен на $new_port"
        echo ""
        warn "Если вы используете фаервол, не забудьте открыть порт $new_port:"
        echo "  ufw allow $new_port/tcp"
    else
        error "Сервис не запустился. Проверьте логи: journalctl -u telemt -n 20"
    fi

    pause
}

change_user_limit() {
    clear
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}           ИЗМЕНЕНИЕ ЛИМИТА ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    users=$(get_users_list)

    if [[ -z "$users" ]]; then
        warn "Нет добавленных пользователей"
        pause
        return
    fi

    declare -A current_limits
    while IFS='=' read -r user limit; do
        user=$(echo "$user" | xargs)
        limit=$(echo "$limit" | xargs)
        if [[ -n "$user" && "$limit" =~ ^[0-9]+$ ]]; then
            current_limits["$user"]="$limit"
        fi
    done < <(sed -n '/^\[access.user_max_unique_ips\]/,/^\[/p' $TELEMT_CONFIG | grep -E '^[a-zA-Z0-9_-]+ = [0-9]+' 2>/dev/null || true)

    echo -e "${CYAN}Существующие пользователи:${NC}"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "${CYAN}%-4s %-20s %-15s${NC}\n" "№" "ИМЯ" "ТЕКУЩИЙ ЛИМИТ"
    echo "─────────────────────────────────────────────────────────────────────────────"

    line_num=1
    declare -a usernames
    while IFS='=' read -r username secret_part; do
        username=$(echo "$username" | xargs)
        if [[ -n "$username" && "$username" != "#"* ]]; then
            limit="${current_limits[$username]:-без лимита}"
            printf "%-4s %-20s %-15s\n" "$line_num" "$username" "$limit"
            usernames[$line_num]=$username
            ((line_num++))
        fi
    done <<< "$users"
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo ""

    users_count=$((line_num - 1))

    if [[ $users_count -eq 0 ]]; then
        warn "Нет пользователей"
        pause
        return
    fi

    read -p "Введите номер пользователя (1-$users_count): " user_num

    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [[ $user_num -lt 1 ]] || [[ $user_num -ge $line_num ]]; then
        error "Неверный номер"
        pause
        return
    fi

    username="${usernames[$user_num]}"
    current_limit="${current_limits[$username]:-0}"

    echo ""
    echo -e "${CYAN}Пользователь:${NC} ${YELLOW}$username${NC}"
    echo -e "${CYAN}Текущий лимит:${NC} ${YELLOW}$([ "$current_limit" == "0" ] && echo "без лимита" || echo "$current_limit IP")${NC}"
    echo ""
    echo "Выберите новый лимит:"
    echo "  1) Без лимита (0)"
    echo "  2) 1 IP одновременно"
    echo "  3) Свой вариант (введите число)"
    read -p "Выбор [1-3]: " limit_choice

    case $limit_choice in
        1) new_limit="0" ;;
        2) new_limit="1" ;;
        3) 
            read -p "Введите количество IP (число): " new_limit
            if ! [[ "$new_limit" =~ ^[0-9]+$ ]]; then
                error "Неверное значение. Введите число."
                pause
                return
            fi
            ;;
        *)
            error "Неверный выбор"
            pause
            return
            ;;
    esac

    if ! grep -q "^\[access.user_max_unique_ips\]" $TELEMT_CONFIG; then
        echo "" >> $TELEMT_CONFIG
        echo "[access.user_max_unique_ips]" >> $TELEMT_CONFIG
    fi

    sed -i "/^$username = /d" $TELEMT_CONFIG

    if [[ "$new_limit" != "0" ]]; then
        sed -i "/^\[access.user_max_unique_ips\]/a $username = $new_limit" $TELEMT_CONFIG
        success "Для пользователя $username установлен лимит: $new_limit IP"
    else
        success "Для пользователя $username убран лимит"
    fi

    fix_config_permissions
    systemctl restart telemt

    pause
}

# ============================================
# Управление Telegram ботом
# ============================================
install_bot() {
    clear
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}           УСТАНОВКА TELEGRAM БОТА${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        error "Сначала установите telemt (пункт 1)"
        pause
        return
    fi

    step "Установка Python и pip..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y python3 python3-pip
    elif command -v yum &>/dev/null; then
        yum install -y python3 python3-pip
    fi

    step "Установка python-telegram-bot..."
    pip3 install python-telegram-bot --break-system-packages 2>/dev/null || pip3 install python-telegram-bot

    step "Создание директории для бота..."
    mkdir -p $BOT_DIR

    echo ""
    echo -e "${CYAN}Для настройки бота вам понадобится:${NC}"
    echo "1. Токен бота от @BotFather"
    echo "2. Ваш Telegram ID (можно узнать у @userinfobot)"
    echo ""

    read -p "Введите токен бота: " BOT_TOKEN
    if [[ -z "$BOT_TOKEN" ]]; then
        error "Токен не может быть пустым"
        pause
        return
    fi

    read -p "Введите ваш Telegram ID (число): " ADMIN_ID
    if ! [[ "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        error "ID должен быть числом"
        pause
        return
    fi

    step "Создание скрипта бота..."
    create_bot_script "$BOT_TOKEN" "$ADMIN_ID"

    step "Создание systemd сервиса для бота..."
    create_bot_service

    step "Запуск бота..."
    systemctl daemon-reload
    systemctl enable telemt-bot
    systemctl start telemt-bot

    sleep 2

    if systemctl is-active --quiet telemt-bot; then
        success "Telegram бот успешно установлен и запущен!"
        echo ""
        echo -e "${CYAN}Бот доступен в Telegram по ссылке:${NC}"
        echo "https://t.me/$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getMe" | grep -oP '"username":"\K[^"]+')"
        echo ""
        echo -e "${YELLOW}Отправьте команду /start в боте для начала работы${NC}"
    else
        warn "Бот не запустился. Проверьте логи: journalctl -u telemt-bot -n 20"
    fi

    pause
}

create_bot_script() {
    local token="$1"
    local admin_id="$2"

    cat > $BOT_SCRIPT << 'PYTHON_EOF'
#!/usr/bin/env python3
import os
import subprocess
import logging
import re
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

TOKEN = "TOKEN_PLACEHOLDER"
ADMIN_IDS = [ADMIN_ID_PLACEHOLDER]
TELEMT_CONFIG = "/etc/telemt/config.toml"

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)
user_inputs = {}

def is_admin(user_id):
    return user_id in ADMIN_IDS

def get_current_port():
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            for line in f:
                if 'port =' in line and not line.startswith('#'):
                    return line.split('=')[1].strip()
    except:
        pass
    return "7443"

def get_current_sni():
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            for line in f:
                if 'tls_domain =' in line and not line.startswith('#'):
                    return line.split('=')[1].strip().strip('"')
    except:
        pass
    return "www.google.com"

def get_users():
    users = []
    try:
        in_users_section = False
        with open(TELEMT_CONFIG, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('[access.users]'):
                    in_users_section = True
                    continue
                if in_users_section and line.startswith('['):
                    break
                if in_users_section and '=' in line and not line.startswith('#'):
                    parts = line.split('=', 1)
                    if len(parts) == 2:
                        username = parts[0].strip()
                        secret = parts[1].strip().strip('"')
                        if username and secret and re.match(r'^[a-f0-9]{32}$', secret):
                            users.append({'name': username, 'secret': secret})
    except Exception as e:
        logger.error(f"Ошибка чтения пользователей: {e}")
    return users

def get_user_limit(username):
    try:
        in_limits = False
        with open(TELEMT_CONFIG, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('[access.user_max_unique_ips]'):
                    in_limits = True
                    continue
                if in_limits and line.startswith('['):
                    break
                if in_limits and '=' in line:
                    parts = line.split('=', 1)
                    if len(parts) == 2:
                        user = parts[0].strip()
                        limit = parts[1].strip()
                        if user == username and limit.isdigit():
                            return int(limit)
    except Exception as e:
        logger.error(f"Ошибка чтения лимита: {e}")
    return 0

def set_user_limit(username, limit):
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            lines = f.readlines()

        with open(TELEMT_CONFIG, 'w') as f:
            in_limits = False
            for line in lines:
                if '[access.user_max_unique_ips]' in line:
                    in_limits = True
                    f.write(line)
                    continue
                if in_limits and line.startswith('['):
                    in_limits = False

                if in_limits and line.strip().startswith(f'{username} ='):
                    continue
                f.write(line)

        if limit > 0:
            with open(TELEMT_CONFIG, 'r') as f:
                lines = f.readlines()

            with open(TELEMT_CONFIG, 'w') as f:
                for line in lines:
                    f.write(line)
                    if '[access.user_max_unique_ips]' in line:
                        f.write(f'{username} = {limit}\n')

        subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        return True
    except Exception as e:
        logger.error(f"Ошибка установки лимита: {e}")
        return False

def add_user_to_config(username, secret):
    try:
        if not re.match(r'^[a-zA-Z0-9_-]+$', username):
            return False
        existing_users = get_users()
        for u in existing_users:
            if u['name'] == username:
                return False

        with open(TELEMT_CONFIG, 'r') as f:
            lines = f.readlines()

        has_users_section = any('[access.users]' in line for line in lines)

        with open(TELEMT_CONFIG, 'w') as f:
            for line in lines:
                f.write(line)
                if '[access.users]' in line:
                    f.write(f'{username} = "{secret}"\n')
            if not has_users_section:
                f.write('\n[access.users]\n')
                f.write(f'{username} = "{secret}"\n')

        subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        return True
    except Exception as e:
        logger.error(f"Ошибка добавления пользователя: {e}")
        return False

def remove_user_from_config(username):
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            lines = f.readlines()
        with open(TELEMT_CONFIG, 'w') as f:
            in_users_section = False
            for line in lines:
                if '[access.users]' in line:
                    in_users_section = True
                    f.write(line)
                    continue
                if in_users_section and line.startswith('['):
                    in_users_section = False
                if line.strip().startswith(f'{username} ='):
                    continue
                f.write(line)
        subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        return True
    except Exception as e:
        logger.error(f"Ошибка удаления пользователя: {e}")
        return False

def change_sni_in_config(new_sni):
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            content = f.read()
        content = re.sub(r'tls_domain = "[^"]*"', f'tls_domain = "{new_sni}"', content)
        with open(TELEMT_CONFIG, 'w') as f:
            f.write(content)
        subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        return True
    except Exception as e:
        logger.error(f"Ошибка изменения SNI: {e}")
        return False

def change_port_in_config(new_port):
    try:
        with open(TELEMT_CONFIG, 'r') as f:
            content = f.read()
        content = re.sub(r'port = \d+', f'port = {new_port}', content)
        with open(TELEMT_CONFIG, 'w') as f:
            f.write(content)
        subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        return True
    except Exception as e:
        logger.error(f"Ошибка изменения порта: {e}")
        return False

def generate_secret():
    random_part = subprocess.run(['openssl', 'rand', '-hex', '16'], capture_output=True, text=True).stdout.strip()
    sni = get_current_sni()
    sni_hex = subprocess.run(['xxd', '-p'], input=sni, capture_output=True, text=True).stdout.strip().replace('\n', '')
    return f"ee{random_part}{sni_hex}"

def get_server_ip():
    result = subprocess.run(['curl', '-4', '-s', 'ifconfig.me'], capture_output=True, text=True)
    ip = result.stdout.strip()
    if not ip:
        result = subprocess.run(['curl', '-4', '-s', 'icanhazip.com'], capture_output=True, text=True)
        ip = result.stdout.strip()
    return ip if ip else "IP_НЕ_ОПРЕДЕЛЕН"

def get_server_info():
    status = subprocess.run(['systemctl', 'is-active', 'telemt'], capture_output=True, text=True).stdout.strip()
    status_emoji = "🟢" if status == "active" else "🔴"
    users = get_users()
    return (f"{status_emoji} *Статус:* {status}\n"
            f"🌐 *IP:* `{get_server_ip()}`\n"
            f"🔌 *Порт:* `{get_current_port()}`\n"
            f"🔒 *SNI:* `{get_current_sni()}`\n"
            f"👥 *Пользователей:* {len(users)}")

def get_main_keyboard():
    keyboard = [
        [InlineKeyboardButton("📊 Статус", callback_data="status")],
        [InlineKeyboardButton("👥 Список пользователей", callback_data="list_users")],
        [InlineKeyboardButton("➕ Добавить пользователя", callback_data="add_user")],
        [InlineKeyboardButton("❌ Удалить пользователя", callback_data="remove_user")],
        [InlineKeyboardButton("🔒 Сменить SNI", callback_data="change_sni")],
        [InlineKeyboardButton("🔌 Сменить порт", callback_data="change_port")],
        [InlineKeyboardButton("🔢 Лимит IP для пользователя", callback_data="change_limit")],
        [InlineKeyboardButton("🔄 Перезапустить telemt", callback_data="restart")],
    ]
    return InlineKeyboardMarkup(keyboard)

def get_cancel_keyboard():
    return InlineKeyboardMarkup([[InlineKeyboardButton("❌ Отмена", callback_data="cancel_input")]])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id):
        await update.message.reply_text("⛔ Доступ запрещён.")
        return
    await update.message.reply_text(
        "🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:",
        reply_markup=get_main_keyboard(),
        parse_mode='Markdown'
    )

async def button_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await query.edit_message_text("⛔ Доступ запрещён.")
        return
    data = query.data

    if data == "status":
        info = get_server_info()
        await query.edit_message_text(f"📊 *Информация о сервере*\n\n{info}", parse_mode='Markdown', reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))

    elif data == "list_users":
        users = get_users()
        if not users:
            await query.edit_message_text("📭 Нет добавленных пользователей", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))
            return

        current_sni = get_current_sni()
        current_port = get_current_port()
        server_ip = get_server_ip()
        sni_hex = subprocess.run(['xxd', '-p'], input=current_sni, capture_output=True, text=True).stdout.strip().replace('\n', '')

        text = "👥 *Список пользователей:*\n\n"
        for i, user in enumerate(users, 1):
            limit = get_user_limit(user['name'])
            limit_text = f" 🔒 лимит: {limit} IP" if limit > 0 else ""

            full_secret = f"ee{user['secret']}{sni_hex}"
            tg_link = f"tg://proxy?server={server_ip}&port={current_port}&secret={full_secret}"
            https_link = f"https://t.me/proxy?server={server_ip}&port={current_port}&secret={full_secret}"

            text += f"*{i}. {user['name']}*{limit_text}\n"
            text += f"📱 TG: `{tg_link}`\n"
            text += f"🌐 HTTP: `{https_link}`\n\n"

        await query.edit_message_text(text, parse_mode='Markdown', reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))

    elif data == "add_user":
        user_inputs[user_id] = {'action': 'add_user'}
        await query.edit_message_text("Введите имя пользователя (только латиница, цифры, - и _):", reply_markup=get_cancel_keyboard())

    elif data == "remove_user":
        users = get_users()
        if not users:
            await query.edit_message_text("📭 Нет пользователей для удаления", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))
            return
        keyboard = [[InlineKeyboardButton(f"❌ {user['name']}", callback_data=f"remove_{user['name']}")] for user in users]
        keyboard.append([InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")])
        await query.edit_message_text("Выберите пользователя для удаления:", reply_markup=InlineKeyboardMarkup(keyboard))

    elif data.startswith("remove_"):
        username = data.replace("remove_", "")
        if remove_user_from_config(username):
            await query.edit_message_text(f"✅ Пользователь *{username}* удалён", parse_mode='Markdown')
        else:
            await query.edit_message_text("❌ Ошибка при удалении")
        await query.edit_message_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')

    elif data == "change_sni":
        user_inputs[user_id] = {'action': 'change_sni'}
        await query.edit_message_text("Введите новый SNI (например: cloudflare.com):", reply_markup=get_cancel_keyboard())

    elif data == "change_port":
        user_inputs[user_id] = {'action': 'change_port'}
        await query.edit_message_text("Введите новый порт (1-65535):", reply_markup=get_cancel_keyboard())

    elif data == "change_limit":
        users = get_users()
        if not users:
            await query.edit_message_text("📭 Нет пользователей для изменения лимита", reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")]]))
            return

        keyboard = []
        for user in users:
            current_limit = get_user_limit(user['name'])
            limit_text = f" (текущий: {current_limit} IP)" if current_limit > 0 else " (без лимита)"
            keyboard.append([InlineKeyboardButton(f"🔢 {user['name']}{limit_text}", callback_data=f"limit_{user['name']}")])
        keyboard.append([InlineKeyboardButton("🔙 Назад", callback_data="back_to_menu")])

        await query.edit_message_text("Выберите пользователя для изменения лимита IP:", reply_markup=InlineKeyboardMarkup(keyboard))

    elif data.startswith("limit_"):
        username = data.replace("limit_", "")
        user_inputs[user_id] = {'action': 'change_limit', 'username': username}
        await query.edit_message_text(
            f"Введите новый лимит IP для пользователя *{username}*\n"
            f"0 - без лимита\n"
            f"1 - только один IP одновременно\n"
            f"любое другое число - максимальное количество уникальных IP",
            parse_mode='Markdown',
            reply_markup=get_cancel_keyboard()
        )

    elif data == "restart":
        await query.edit_message_text("🔄 Перезапуск telemt...")
        subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
        await query.edit_message_text("✅ Telemt перезапущен\n\n🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')

    elif data == "back_to_menu":
        await query.edit_message_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')

    elif data == "cancel_input":
        if user_id in user_inputs:
            del user_inputs[user_id]
        await query.edit_message_text("❌ Действие отменено\n\n🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
    return

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if not is_admin(user_id):
        await update.message.reply_text("⛔ Доступ запрещён.")
        return
    if user_id not in user_inputs:
        return
    action = user_inputs[user_id]['action']
    text = update.message.text.strip()

    if action == 'add_user':
        if not re.match(r'^[a-zA-Z0-9_-]+$', text):
            await update.message.reply_text("❌ Имя пользователя может содержать только латинские буквы, цифры, - и _")
            await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
            del user_inputs[user_id]
            return
        existing_users = get_users()
        for u in existing_users:
            if u['name'] == text:
                await update.message.reply_text(f"❌ Пользователь *{text}* уже существует!", parse_mode='Markdown')
                await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
                del user_inputs[user_id]
                return
        secret = generate_secret()
        random_part = secret[2:34]
        if add_user_to_config(text, random_part):
            ip = get_server_ip()
            port = get_current_port()
            tg_link = f"tg://proxy?server={ip}&port={port}&secret={secret}"
            https_link = f"https://t.me/proxy?server={ip}&port={port}&secret={secret}"
            await update.message.reply_text(f"✅ *Пользователь добавлен!*\n\n👤 *Имя:* `{text}`\n\n🔗 *Ссылка для Telegram (нажмите для установки):*\n{tg_link}\n\n📋 *Ссылка для копирования:*\n`{https_link}`", parse_mode='Markdown')
        else:
            await update.message.reply_text("❌ Ошибка при добавлении пользователя")
        await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
        del user_inputs[user_id]

    elif action == 'change_sni':
        try:
            with open(TELEMT_CONFIG, 'r') as f:
                content = f.read()
            content = re.sub(r'tls_domain = "[^"]*"', f'tls_domain = "{text}"', content)
            with open(TELEMT_CONFIG, 'w') as f:
                f.write(content)
            subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
            subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
            subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
            await update.message.reply_text(f"✅ SNI изменён на `{text}`", parse_mode='Markdown')
        except Exception as e:
            await update.message.reply_text("❌ Ошибка при изменении SNI")
        await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
        del user_inputs[user_id]

    elif action == 'change_port':
        if not text.isdigit() or int(text) < 1 or int(text) > 65535:
            await update.message.reply_text("❌ Неверный порт. Введите число от 1 до 65535.")
            return
        try:
            with open(TELEMT_CONFIG, 'r') as f:
                content = f.read()
            content = re.sub(r'port = \d+', f'port = {text}', content)
            with open(TELEMT_CONFIG, 'w') as f:
                f.write(content)
            subprocess.run(['chown', 'telemt:telemt', TELEMT_CONFIG], capture_output=True)
            subprocess.run(['chmod', '644', TELEMT_CONFIG], capture_output=True)
            subprocess.run(['systemctl', 'restart', 'telemt'], capture_output=True)
            await update.message.reply_text(f"✅ Порт изменён на `{text}`", parse_mode='Markdown')
        except Exception as e:
            await update.message.reply_text("❌ Ошибка при изменении порта")
        await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
        del user_inputs[user_id]

    elif action == 'change_limit':
        username = user_inputs[user_id].get('username')
        if not username:
            await update.message.reply_text("❌ Ошибка: пользователь не выбран")
            await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
            del user_inputs[user_id]
            return

        if not text.isdigit():
            await update.message.reply_text("❌ Введите число (0 - без лимита, 1 - один IP, и т.д.)")
            return

        new_limit = int(text)

        if set_user_limit(username, new_limit):
            if new_limit == 0:
                await update.message.reply_text(f"✅ Для пользователя *{username}* убран лимит IP", parse_mode='Markdown')
            else:
                await update.message.reply_text(f"✅ Для пользователя *{username}* установлен лимит: {new_limit} IP", parse_mode='Markdown')
        else:
            await update.message.reply_text("❌ Ошибка при установке лимита")

        await update.message.reply_text("🤖 *Telemt Bot*\n\n*Передай привеД ПОТАПу !!!*\n\nВыберите действие:", reply_markup=get_main_keyboard(), parse_mode='Markdown')
        del user_inputs[user_id]

def main():
    application = Application.builder().token(TOKEN).build()
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CallbackQueryHandler(button_callback))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    print("🤖 Бот запущен...")
    application.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == '__main__':
    main()
PYTHON_EOF

    sed -i "s/TOKEN_PLACEHOLDER/$token/" $BOT_SCRIPT
    sed -i "s/ADMIN_ID_PLACEHOLDER/$admin_id/" $BOT_SCRIPT
    chmod +x $BOT_SCRIPT
}

create_bot_service() {
    cat > $BOT_SERVICE << EOF
[Unit]
Description=Telemt Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=/usr/bin/python3 $BOT_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

uninstall_bot() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ TELEGRAM БОТА${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ ! -f "$BOT_SERVICE" ]] && [[ ! -d "$BOT_DIR" ]]; then
        warn "Telegram бот не установлен"
        pause
        return
    fi

    warn "ВНИМАНИЕ! Это действие полностью удалит Telegram бота:"
    echo "  • Директория: $BOT_DIR"
    echo "  • Systemd сервис: telemt-bot"
    echo "  • Python зависимости (python-telegram-bot)"
    echo ""
    read -p "Вы уверены, что хотите удалить бота? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi

    step "Остановка сервиса бота..."
    systemctl stop telemt-bot 2>/dev/null
    systemctl disable telemt-bot 2>/dev/null

    step "Удаление файлов..."
    rm -f $BOT_SERVICE
    rm -rf $BOT_DIR

    step "Удаление Python зависимостей..."
    pip3 uninstall -y python-telegram-bot 2>/dev/null || true

    step "Обновление systemd..."
    systemctl daemon-reload

    success "Telegram бот полностью удален"
    pause
}

# ============================================
# Функции для Web панели Telemt Panel
# ============================================
install_telemt_panel() {
    clear
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}           УСТАНОВКА WEB ПАНЕЛИ TELEMT${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Проверка наличия telemt
    if ! check_telemt_installed; then
        error "Сначала установите telemt (пункт 1)"
        pause
        return
    fi

    # Проверка наличия telemt API
    if ! grep -q "enabled = true" $TELEMT_CONFIG || ! grep -q "listen = \"127.0.0.1:9091\"" $TELEMT_CONFIG; then
        error "В конфиге telemt не включён API. Пожалуйста, проверьте конфиг."
        pause
        return
    fi

    step "Установка Nginx..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y nginx
    elif command -v yum &>/dev/null; then
        yum install -y nginx
    else
        error "Не удалось установить Nginx"
        pause
        return
    fi

    # Запрос порта для веб-панели
    echo ""
    read -p "Введите порт для веб-панели (по умолчанию 8443, от 1024 до 65535): " panel_port
    if [[ -z "$panel_port" ]]; then
        panel_port="8443"
    fi
    if ! [[ "$panel_port" =~ ^[0-9]+$ ]] || [[ $panel_port -lt 1024 ]] || [[ $panel_port -gt 65535 ]]; then
        error "Неверный порт. Используется порт 8443"
        panel_port="8443"
    fi

    # Проверка, не занят ли порт
    if ss -tlnp | grep -q ":$panel_port "; then
        warn "Порт $panel_port уже занят!"
        read -p "Использовать другой порт? (y/N): " change_port
        if [[ "$change_port" == "y" || "$change_port" == "Y" ]]; then
            read -p "Введите новый порт: " panel_port
            if ! [[ "$panel_port" =~ ^[0-9]+$ ]] || [[ $panel_port -lt 1024 ]] || [[ $panel_port -gt 65535 ]]; then
                error "Неверный порт. Установка отменена"
                pause
                return
            fi
        fi
    fi

    # Запрос типа сертификатов
    echo ""
    echo "Выберите тип сертификата:"
    echo "  1) Самоподписные (10 лет)"
    echo "  2) Использовать существующие"
    read -p "Выбор [1-2]: " cert_choice

    case $cert_choice in
        2)
            read -p "Введите путь к сертификату (.crt): " custom_crt
            read -p "Введите путь к приватному ключу (.key): " custom_key
            if [[ ! -f "$custom_crt" ]] || [[ ! -f "$custom_key" ]]; then
                error "Файлы сертификатов не найдены. Будет использован самоподписной сертификат"
                cert_choice=1
            fi
            ;;
        *)
            cert_choice=1
            ;;
    esac

    # Запрос логина и пароля для панели
    echo ""
    read -p "Введите логин администратора панели (по умолчанию admin): " panel_user
    panel_user=${panel_user:-admin}

    read -sp "Введите пароль администратора: " panel_password
    echo ""
    if [[ -z "$panel_password" ]]; then
        panel_password="admin123"
        warn "Пароль не введён. Установлен пароль по умолчанию: admin123"
    fi

    step "Скачивание и установка Telemt Panel..."
    curl -fsSL https://raw.githubusercontent.com/amirotin/telemt_panel/main/install.sh -o $PANEL_INSTALL_SCRIPT
    bash $PANEL_INSTALL_SCRIPT

    # Останавливаем панель для настройки
    systemctl stop telemt-panel 2>/dev/null

    step "Настройка конфигурации панели..."

    # Генерируем хеш пароля
    panel_password_hash=$(/opt/bin/telemt/telemt-panel hash-password 2>/dev/null | grep -oP 'hash: \K.*' || echo "")
    if [[ -z "$panel_password_hash" ]]; then
        panel_password_hash=$(echo -n "$panel_password" | htpasswd -bnBC 10 "" | tr -d ':\n' | sed 's/$2y/$2a/')
    fi

    # Генерируем JWT секрет
    jwt_secret=$(openssl rand -hex 32)

    # Создаём конфиг панели
    mkdir -p /opt/etc/telemt-panel
    cat > $PANEL_CONFIG << EOF
listen = "127.0.0.1:8080"

[telemt]
url = "http://127.0.0.1:9091"
binary_path = "$TELEMT_BIN"
service_name = "telemt"
github_repo = "telemt/telemt"

[panel]
binary_path = "$PANEL_BIN"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"

[auth]
username = "$panel_user"
password_hash = "$panel_password_hash"
jwt_secret = "$jwt_secret"
session_ttl = "24h"

[cors]
allowed_origins = ["*"]
EOF
    chmod 600 $PANEL_CONFIG

    step "Настройка сертификатов..."
    server_ip=$(get_server_ip)

    if [[ $cert_choice -eq 2 ]] && [[ -f "$custom_crt" ]] && [[ -f "$custom_key" ]]; then
        cp "$custom_crt" $PANEL_SSL_CRT
        cp "$custom_key" $PANEL_SSL_KEY
        chmod 644 $PANEL_SSL_CRT
        chmod 600 $PANEL_SSL_KEY
    else
        # Создаём самоподписные сертификаты на 10 лет
        step "Создание самоподписных сертификатов на 10 лет..."
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout $PANEL_SSL_KEY \
            -out $PANEL_SSL_CRT \
            -subj "/C=RU/ST=State/L=City/O=Telemt/CN=$server_ip" 2>/dev/null
        chmod 600 $PANEL_SSL_KEY
        chmod 644 $PANEL_SSL_CRT
    fi

    step "Настройка Nginx..."

    # Создаём конфигурацию Nginx
    cat > $PANEL_NGINX_CONF << EOF
server {
    listen $panel_port ssl http2;
    server_name _;

    ssl_certificate $PANEL_SSL_CRT;
    ssl_certificate_key $PANEL_SSL_KEY;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # Включаем конфигурацию
    ln -sf $PANEL_NGINX_CONF $PANEL_NGINX_ENABLED
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    # Проверяем конфигурацию Nginx
    nginx -t
    if [[ $? -ne 0 ]]; then
        error "Ошибка в конфигурации Nginx"
        pause
        return
    fi

    step "Настройка фаервола..."
    if command -v ufw &>/dev/null; then
        ufw allow $panel_port/tcp
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=$panel_port/tcp
        firewall-cmd --reload
    fi

    step "Запуск сервисов..."
    systemctl daemon-reload
    systemctl enable telemt-panel
    systemctl restart telemt-panel
    systemctl restart nginx

    sleep 3

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}WEB ПАНЕЛЬ TELEMT УСПЕШНО УСТАНОВЛЕНА!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Доступ к панели:${NC} https://$server_ip:$panel_port"
    echo -e "${YELLOW}Логин:${NC} $panel_user"
    echo -e "${YELLOW}Пароль:${NC} $panel_password"
    echo ""
    echo -e "${YELLOW}⚠️  Важно:${NC}"
    echo "  • Панель доступна по HTTPS на порту $panel_port"
    echo "  • Используется самоподписной сертификат (браузер может показывать предупреждение)"
    echo "  • Для управления панелью войдите с указанными логином и паролем"
    echo ""
    echo -e "${BLUE}Проверка статуса:${NC}"
    systemctl status telemt-panel --no-pager -l
    echo ""
    echo -e "${BLUE}Логи панели:${NC} sudo journalctl -u telemt-panel -f"
    echo -e "${BLUE}Логи Nginx:${NC} sudo journalctl -u nginx -f"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    pause
}

uninstall_telemt_panel() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ WEB ПАНЕЛИ TELEMT${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ ! -f "$PANEL_BIN" ]] && [[ ! -f "$PANEL_SERVICE" ]]; then
        warn "Web панель Telemt не установлена"
        pause
        return
    fi

    warn "ВНИМАНИЕ! Это действие удалит Web панель и её настройки:"
    echo "  • Бинарник панели"
    echo "  • Конфигурацию панели"
    echo "  • Systemd сервис"
    echo "  • Настройки Nginx для панели"
    echo ""
    echo -e "${YELLOW}⚠️  При этом НЕ будут удалены:${NC}"
    echo "  • Telemt (основной прокси)"
    echo "  • Telegram бот"
    echo "  • Созданные пользователи прокси"
    echo ""
    read -p "Вы уверены, что хотите удалить Web панель? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi

    step "Остановка сервисов..."
    systemctl stop telemt-panel 2>/dev/null
    systemctl disable telemt-panel 2>/dev/null
    systemctl stop nginx 2>/dev/null

    step "Удаление файлов панели..."
    rm -f $PANEL_SERVICE
    rm -f $PANEL_BIN
    rm -rf /opt/bin/telemt
    rm -rf /opt/etc/telemt-panel
    rm -rf /var/lib/telemt-panel

    step "Удаление конфигурации Nginx..."
    rm -f $PANEL_NGINX_CONF
    rm -f $PANEL_NGINX_ENABLED

    step "Удаление сертификатов..."
    rm -f $PANEL_SSL_KEY
    rm -f $PANEL_SSL_CRT

    step "Восстановление Nginx (если нужно)..."
    if [[ ! -f /etc/nginx/sites-enabled/default ]] && [[ -f /etc/nginx/sites-available/default ]]; then
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi

    step "Перезапуск Nginx..."
    systemctl restart nginx 2>/dev/null

    step "Обновление systemd..."
    systemctl daemon-reload

    success "Web панель Telemt полностью удалена"
    pause
}

# ============================================
# Статус и информация
# ============================================
show_status() {
    clear
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}           СТАТУС TELEMT${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if ! check_telemt_installed; then
        pause
        return
    fi

    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}● Telemt: АКТИВЕН${NC}"
    else
        echo -e "${RED}● Telemt: НЕ АКТИВЕН${NC}"
    fi

    if systemctl is-active --quiet telemt-bot 2>/dev/null; then
        echo -e "${GREEN}● Telegram бот: АКТИВЕН${NC}"
    else
        echo -e "${RED}● Telegram бот: НЕ АКТИВЕН${NC}"
    fi

    if systemctl is-active --quiet telemt-panel 2>/dev/null; then
        echo -e "${GREEN}● Web панель: АКТИВЕН${NC}"
        server_ip=$(get_server_ip)
        panel_port=$(grep -oP "listen \K\d+" $PANEL_NGINX_CONF 2>/dev/null || echo "8443")
        echo -e "${GREEN}   Доступ: https://$server_ip:$panel_port${NC}"
    else
        echo -e "${RED}● Web панель: НЕ АКТИВЕН${NC}"
    fi

    echo ""

    if $TELEMT_BIN --version &>/dev/null; then
        version=$($TELEMT_BIN --version 2>&1 | head -1)
        echo -e "${CYAN}● Версия telemt:${NC} $version"
    fi

    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    echo -e "${CYAN}● Порт telemt:${NC} $current_port"

    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    echo -e "${CYAN}● SNI:${NC} $current_sni"

    users_count=$(get_users_count)
    echo -e "${CYAN}● Пользователей:${NC} $users_count"

    server_ip=$(get_server_ip)
    echo -e "${CYAN}● IPv4 сервера:${NC} $server_ip"

    echo ""
    echo -e "${YELLOW}Метрики Prometheus:${NC} http://127.0.0.1:9091/metrics"
    echo -e "${YELLOW}API:${NC} http://127.0.0.1:9091/v1/users"

    echo ""
    echo -e "${BLUE}Последние логи telemt:${NC}"
    journalctl -u telemt -n 3 --no-pager 2>/dev/null || echo "  (логи недоступны)"

    if systemctl is-active --quiet telemt-bot 2>/dev/null; then
        echo ""
        echo -e "${BLUE}Последние логи бота:${NC}"
        journalctl -u telemt-bot -n 3 --no-pager 2>/dev/null || echo "  (логи недоступны)"
    fi

    if systemctl is-active --quiet telemt-panel 2>/dev/null; then
        echo ""
        echo -e "${BLUE}Последние логи панели:${NC}"
        journalctl -u telemt-panel -n 3 --no-pager 2>/dev/null || echo "  (логи недоступны)"
    fi

    pause
}

# ============================================
# Главное меню
# ============================================
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}                         ${MAGENTA}TELEMT${NC}                              ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "          ${YELLOW}Передай привеД ПОТАПу !!!${NC}"
    echo ""
    echo -e "${GREEN}  УСТАНОВКА И УДАЛЕНИЕ${NC}"
    echo -e "  ${GREEN}1)${NC} Установить telemt"
    echo -e "  ${RED}2)${NC} Удалить telemt (полностью)"
    echo ""
    echo -e "${YELLOW}  УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ${NC}"
    echo -e "  ${YELLOW}3)${NC} Добавить пользователя"
    echo -e "  ${YELLOW}4)${NC} Список пользователей"
    echo -e "  ${YELLOW}5)${NC} Удалить пользователя"
    echo ""
    echo -e "${BLUE}  НАСТРОЙКА${NC}"
    echo -e "  ${BLUE}6)${NC} Сменить SNI (TLS маскировку)"
    echo -e "  ${BLUE}7)${NC} Сменить порт"
    echo -e "  ${BLUE}8)${NC} Изменить лимит IP для пользователя"
    echo ""
    echo -e "${CYAN}  ИНФОРМАЦИЯ${NC}"
    echo -e "  ${CYAN}9)${NC} Статус и информация"
    echo ""
    echo -e "${MAGENTA}  TELEGRAM БОТ${NC}"
    echo -e "  ${MAGENTA}10)${NC} Установить Telegram бота"
    echo -e "  ${RED}11)${NC} Удалить Telegram бота"
    echo ""
    echo -e "${MAGENTA}  WEB ПАНЕЛЬ${NC}"
    echo -e "  ${MAGENTA}12)${NC} Установить Web панель Telemt"
    echo -e "  ${RED}13)${NC} Удалить Web панель Telemt"
    echo ""
    echo -e "${RED}  0)${NC} Выход"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "Выберите пункт меню: " choice
}

# ============================================
# Основной цикл
# ============================================
main() {
    check_root

    while true; do
        show_menu
        case $choice in
            1) install_telemt ;;
            2) uninstall_telemt ;;
            3) add_user ;;
            4) list_users ;;
            5) remove_user ;;
            6) change_sni ;;
            7) change_port ;;
            8) change_user_limit ;;
            9) show_status ;;
            10) install_bot ;;
            11) uninstall_bot ;;
            12) install_telemt_panel ;;
            13) uninstall_telemt_panel ;;
            0) 
                clear
                info "До свидания!"
                exit 0
                ;;
            *) 
                error "Неверный выбор. Пожалуйста, выберите от 0 до 13"
                sleep 2
                ;;
        esac
    done
}

main
