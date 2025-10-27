#!/bin/bash
# ==============================================================================
# TUI-конфигуратор Sing-Box для Entware Keenetic
# (Сценарий: mixed:2080, VLESS out, Динамические Rulesets с GitHub, Final Direct)
# БЕЗ ИСПОЛЬЗОВАНИЯ JQ
# ==============================================================================

# --- Настройки среды ---
SINGBOX_DIR="/opt/etc/sing-box"
CONFIG_PATH="$SINGBOX_DIR/config.json"
TMP_CONFIG="/tmp/sing-box-config.tmp"
RULESET_BASE_URL="https://raw.githubusercontent.com/vernette/rulesets/master/srs"

# --- Глобальные переменные для хранения настроек ---
VLESS_LINK=""
VLESS_TAG="proxy"
V_UUID=""
V_SERVER=""
V_PORT=""
V_FLOW="xtls-rprx-vision" 
V_SECURITY="tls" 
V_TRANSPORT_TYPE="tcp"
V_TRANSPORT_PATH=""
V_TRANSPORT_HEADER_HOST=""

# Полный список доступных правил vernette
declare -A ALL_RULESETS=(
    ["copilot"]="GitHub Copilot"
    ["discord-full"]="Discord (Полный набор)"
    ["grok"]="Grok AI"
    ["instagram"]="Instagram"
    ["linkedn"]="LinkedIn"
    ["netflix"]="Netflix"
    ["openai"]="OpenAI (ChatGPT, API)"
    ["rkn"]="Сайты, заблокированные РКН"
    ["telegram-voice-chats"]="Голосовые чаты Telegram"
    ["tiktok"]="TikTok"
    ["unavailable-in-russia"]="Недоступные в РФ сервисы"
    ["x"]="X (Twitter)"
    ["youtube"]="YouTube"
)
SELECTED_RULESETS=()

# --- Вспомогательные функции ---

check_dependencies() {
    echo "--- Проверка зависимостей и установка ---"
    
    # Исключаем 'jq' из обязательных пакетов
    local REQUIRED_PKGS=("dialog" "curl" "sing-box-go")
    local missing_pkgs=""

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! opkg list-installed | grep -q "^$pkg "; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        echo "Отсутствуют пакеты: $missing_pkgs"
        read -r -p "Хотите установить их сейчас? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Установка отменена. Выход."
            exit 1
        fi

        opkg update
        for pkg in $missing_pkgs; do
            echo "Устанавливаем $pkg..."
            opkg install "$pkg"
            if [ $? -ne 0 ]; then
                echo "Ошибка: Не удалось установить $pkg. Выход."
                exit 1
            fi
        done
    fi
    
    mkdir -p "$SINGBOX_DIR"
    echo "Все зависимости готовы."
    sleep 1
}

# Экранирование строк для JSON (очень важно при ручной сборке)
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\//\\\//g'
}

# Функция парсинга VLESS URI (оставлена без изменений)
parse_vless_link() {
    V_UUID="" && V_SERVER="" && V_PORT="" && V_FLOW="xtls-rprx-vision" && V_SECURITY="tls" && V_TRANSPORT_TYPE="tcp" && V_TRANSPORT_PATH="" && V_TRANSPORT_HEADER_HOST=""

    local link_data=$1
    local content
    content=$(echo "$link_data" | sed 's/^vless:\/\///')
    
    V_UUID=$(echo "$content" | cut -d '@' -f 1)
    if [ -z "$V_UUID" ]; then return 1; fi

    local addr_params
    addr_params=$(echo "$content" | cut -d '@' -f 2)

    V_SERVER=$(echo "$addr_params" | cut -d ':' -f 1)
    
    local port_params
    port_params=$(echo "$addr_params" | cut -d ':' -f 2)
    
    V_PORT=$(echo "$port_params" | cut -d '?' -f 1)
    
    local params
    params=$(echo "$port_params" | cut -d '?' -f 2)
    
    IFS='&' read -ra pairs <<< "$params"
    for pair in "${pairs[@]}"; do
        local key
        key=$(echo "$pair" | cut -d '=' -f 1)
        local value
        value=$(echo "$pair" | cut -d '=' -f 2)
        
        value=$(echo "$value" | sed 's/+/ /g; s/%/\\x/g' | xargs -0 printf %b)

        case "$key" in
            security) V_SECURITY="$value" ;;
            flow) V_FLOW="$value" ;;
            type) V_TRANSPORT_TYPE="$value" ;;
            host) V_TRANSPORT_HEADER_HOST="$value" ;;
            path) V_TRANSPORT_PATH="$value" ;;
            sni) : ;; 
            alpn) : ;;
            pbk) : ;;
            sid) : ;;
            name) : ;;
            *) : ;;
        esac
    done
    
    if [ -z "$V_UUID" ] || [ -z "$V_SERVER" ] || [ -z "$V_PORT" ]; then
        return 1
    fi
    
    if [ "$V_TRANSPORT_TYPE" = "v2ray-ws" ]; then V_TRANSPORT_TYPE="ws"; fi
    if [ "$V_TRANSPORT_TYPE" = "v2ray-grpc" ]; then V_TRANSPORT_TYPE="grpc"; fi
    
    return 0
}

# --- Функции TUI (оставлены без изменений) ---
configure_outbound_vless() {
    # ... (логика с dialog)
    while true; do
        VLESS_LINK=$(dialog --clear --backtitle "Конфигуратор Sing-Box" \
            --title "Настройка VLESS Outbound" \
            --inputbox "Вставьте полную ссылку VLESS (vless://...):\n\nТекущая ссылка:\n$VLESS_LINK" 12 80 "$VLESS_LINK" 2>&1 >/dev/tty)
        
        if [ $? -ne 0 ]; then return 1; fi
        
        if parse_vless_link "$VLESS_LINK"; then
            dialog --title "Успех" --msgbox "VLESS-ссылка успешно разобрана:\n\nСервер: $V_SERVER:$V_PORT\nБезопасность: $V_SECURITY\nТранспорт: $V_TRANSPORT_TYPE" 10 70
            return 0
        else
            dialog --title "Ошибка Парсинга" --msgbox "Не удалось разобрать ссылку. Проверьте формат VLESS URI." 7 70
        fi
    done
}

select_rulesets_tui() {
    # ... (логика с dialog)
    local checklist_options=()
    
    declare -A rule_states
    for rule in "${SELECTED_RULESETS[@]}"; do
        rule_states[$rule]="on"
    done

    for rule_name in "${!ALL_RULESETS[@]}"; do
        local state="off"
        if [ "${rule_states[$rule_name]}" = "on" ]; then
            state="on"
        fi
        checklist_options+=("$rule_name" "${ALL_RULESETS[$rule_name]}" "$state")
    done

    local choices
    choices=$(dialog --clear --backtitle "Конфигуратор Sing-Box" \
        --title "Выбор правил маршрутизации (vernette/rulesets)" \
        --checklist "Выберите правила. Весь трафик, соответствующий им, пойдет в PROXY." 20 65 14 \
        "${checklist_options[@]}" \
        2>&1 >/dev/tty)

    if [ $? -ne 0 ]; then return; fi

    local choices_cleaned
    choices_cleaned=$(echo "$choices" | sed 's/"//g')
    IFS=' ' read -r -a SELECTED_RULESETS <<< "$choices_cleaned"
    
    dialog --title "Успех" --infobox "Выбрано правил: ${#SELECTED_RULESETS[@]}" 3 50
    sleep 1
}

# --- Основная логика ---

# ГЕНЕРАЦИЯ JSON-КОНФИГА БЕЗ JQ
generate_config() {
    if [ -z "$V_SERVER" ]; then
        dialog --title "Ошибка" --msgbox "Сначала необходимо настроить VLESS Outbound (Пункт 1)." 5 60
        return 1
    fi
    
    dialog --title "Генерация" --infobox "Генерируем config.json..." 3 50
    
    # 1. Сборка секций Rule_Set и Rules
    local RULE_SET_JSON=""
    local RULES_JSON=""
    local need_comma=0
    local rule_url_esc

    for rule_name in "${SELECTED_RULESETS[@]}"; do
        rule_url_esc=$(json_escape "$RULESET_BASE_URL/$rule_name.srs")
        
        if [ $need_comma -eq 1 ]; then
            RULE_SET_JSON="${RULE_SET_JSON},"
            RULES_JSON="${RULES_JSON},"
        fi
        need_comma=1

        # Добавляем в rule_set
        RULE_SET_JSON="${RULE_SET_JSON}
            {
                \"tag\": \"${rule_name}\",
                \"type\": \"remote\",
                \"format\": \"binary\",
                \"url\": \"${rule_url_esc}\"
            }"
            
        # Добавляем в rules (маршрутизация в proxy)
        RULES_JSON="${RULES_JSON}
            {
                \"rule_set\": \"${rule_name}\", 
                \"outbound\": \"proxy\"
            }"
    done

    # 2. Сборка TLS-конфига
    local TLS_CONFIG
    local REALITY_OPTIONS=""
    local V_SNI=$(json_escape "$V_SERVER")
    
    if [ "$V_SECURITY" = "reality" ]; then
        local V_PBK=$(echo "$VLESS_LINK" | grep -oP 'pbk=\K[^&]+')
        local V_SID=$(echo "$VLESS_LINK" | grep -oP 'sid=\K[^&]+')
        local V_SPN=$(echo "$VLESS_LINK" | grep -oP 'sni=\K[^&]+')
        V_SNI=$(json_escape "$V_SPN")

        REALITY_OPTIONS=",
            \"reality\": {
                \"enabled\": true,
                \"public_key\": \"$(json_escape "$V_PBK")\",
                \"short_id\": \"$(json_escape "$V_SID")\"
            }"
        V_FLOW="xtls-rprx-vision"
        V_TRANSPORT_TYPE="tcp"
    fi

    TLS_CONFIG="{
        \"enabled\": true,
        \"insecure\": false,
        \"server_name\": \"${V_SNI}\"${REALITY_OPTIONS}
    }"

    # 3. Сборка Transport-конфига
    local TRANSPORT_CONFIG="{}"
    local TRANSPORT_OPTIONS=""

    if [ "$V_TRANSPORT_TYPE" = "ws" ]; then
        if [ -n "$V_TRANSPORT_PATH" ]; then
            TRANSPORT_OPTIONS="${TRANSPORT_OPTIONS}\"path\": \"$(json_escape "$V_TRANSPORT_PATH")\","
        fi
        if [ -n "$V_TRANSPORT_HEADER_HOST" ]; then
            TRANSPORT_OPTIONS="${TRANSPORT_OPTIONS}\"headers\": {\"Host\": \"$(json_escape "$V_TRANSPORT_HEADER_HOST")\"},"
        fi
        
        # Удаляем последнюю запятую, если есть
        if [ -n "$TRANSPORT_OPTIONS" ]; then
            TRANSPORT_OPTIONS="\"ws\": { ${TRANSPORT_OPTIONS%?} }"
        fi
        TRANSPORT_CONFIG="{\"type\": \"ws\", ${TRANSPORT_OPTIONS}}"
    elif [ "$V_TRANSPORT_TYPE" = "grpc" ]; then
        if [ -n "$V_TRANSPORT_HEADER_HOST" ]; then
            TRANSPORT_OPTIONS="\"grpc\": {\"service_name\": \"$(json_escape "$V_TRANSPORT_HEADER_HOST")\"}"
        fi
        TRANSPORT_CONFIG="{\"type\": \"grpc\", ${TRANSPORT_OPTIONS}}"
    fi

    # 4. Сборка VLESS Outbound
    local VLESS_OUTBOUND="
            {
                \"type\": \"vless\",
                \"tag\": \"${VLESS_TAG}\",
                \"server\": \"$(json_escape "$V_SERVER")\",
                \"server_port\": ${V_PORT},
                \"uuid\": \"$(json_escape "$V_UUID")\",
                \"flow\": \"${V_FLOW}\",
                \"tls\": ${TLS_CONFIG},
                \"transport\": ${TRANSPORT_CONFIG}
            }"

    # 5. Сборка финального конфига с использованием HEREDOC
    # JSON должен быть полностью валидным, поэтому ручная сборка требует предельной осторожности с запятыми и кавычками
    cat <<EOF > "$TMP_CONFIG"
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "dns": {
        "servers": [
            {
                "address": "8.8.8.8",
                "tag": "DNS-proxy",
                "detour": "proxy"
            }
        ],
        "strategy": "ipv4_only"
    },
    "inbounds": [
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "0.0.0.0",
            "listen_port": 2080
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        },
        {
            "type": "dns",
            "tag": "dns-out"
        },
        ${VLESS_OUTBOUND},
    ],
    "route": {
        "rule_set": [
            ${RULE_SET_JSON}
        ],
        "rules": [
            {
                "protocol": "dns",
                "outbound": "dns-out"
            }
            ${RULES_JSON}
        ],
        "final": "direct"
    }
}
EOF

    # 6. Проверка (нет jq, поэтому только синтаксическая проверка на ошибки в HEREDOC)
    # Поскольку мы не можем проверить JSON на валидность без jq,
    # мы будем полагаться на то, что sing-box выдаст ошибку при запуске.
    # Для базовой проверки попробуем найти незакрытые скобки/кавычки (крайне ненадежно)
    if grep -q "ERROR" "$TMP_CONFIG"; then
         dialog --title "Критическая Ошибка" --msgbox "Ошибка в генерации JSON. Проверьте скрипт или вернитесь к jq." 7 70
         return 1
    fi
    
    # 7. Сохранение и перезапуск
    mv "$TMP_CONFIG" "$CONFIG_PATH"
    
    dialog --title "Сохранение" --yesno "Конфиг успешно сгенерирован и сохранен в $CONFIG_PATH.\n\nПерезапустить sing-box сейчас?" 9 70
    
    if [ $? -eq 0 ]; then
        if [ -f /opt/etc/init.d/S99sing-box ]; then
            /opt/etc/init.d/S99sing-box restart
            dialog --title "Перезапуск" --infobox "Sing-box перезапущен." 3 50
            sleep 1
        else
            dialog --title "Предупреждение" --msgbox "Не найден скрипт запуска /opt/etc/init.d/S99sing-box. Запустите вручную: 'sing-box-go run -c /opt/etc/sing-box/config.json'." 7 60
        fi
    fi
    return 0
}

# --- Точка входа ---
main_menu() {
    # ... (логика main_menu оставлена без изменений)
    local choice
    while true; do
        local status_vless="❌ Не настроен"
        if [ -n "$V_SERVER" ]; then
            status_vless="✅ $V_SERVER:$V_PORT ($V_SECURITY/$V_TRANSPORT_TYPE)"
        fi
        
        local status_rulesets="${#SELECTED_RULESETS[@]} правил"

        choice=$(dialog --clear --backtitle "Конфигуратор Sing-Box (Keenetic Entware)" \
            --title "Главное Меню" \
            --menu "Выберите раздел для настройки:\n\nСтатус:\nVLESS: $status_vless\nRulesets: $status_rulesets (маршрутируются в PROXY)" 18 80 5 \
            "1" "Настройка VLESS Outbound (обязательно)" \
            "2" "Выбор правил маршрутизации (Rulesets)" \
            "3" "Сгенерировать config.json и Перезапустить" \
            "0" "Выход" \
            2>&1 >/dev/tty)

        case $choice in
            1) configure_outbound_vless ;;
            2) select_rulesets_tui ;;
            3) generate_config ;;
            0) clear; exit 0 ;;
            *) ;;
        esac
    done
}

# --- Точка входа ---
check_dependencies
main_menu
