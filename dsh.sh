#!/bin/bash
# =============================================================================
#  DeepSeek Harness (dsh) — установка / обновление / удаление / бэкап
#  Версия 3.2 — меню «Показать URL с токеном», не сжигает токен при проверке
#
#  Использование:
#    ./dsh.sh              — интерактивное меню
#    ./dsh.sh install      — установить последнюю версию
#    ./dsh.sh update       — обновить (с бэкапом)
#    ./dsh.sh uninstall    — удалить dsh
#    ./dsh.sh restore      — восстановить из бэкапа
#    ./dsh.sh token        — показать URL для входа с токеном
# =============================================================================

set -uo pipefail

# ---------- Определение пользователя ----------
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    RUN_USER="$SUDO_USER"
    RUN_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    export HOME="$RUN_HOME" USER="$RUN_USER"
elif [ "$EUID" -eq 0 ]; then
    RUN_USER="root"; RUN_HOME="$HOME"
else
    RUN_USER="$USER"; RUN_HOME="$HOME"
fi

# ---------- Настройки ----------
SCRIPT_VERSION="3.2"
DSH_PORT="${DSH_PORT:-3080}"
SKIP_PLUGIN_INSTALL="${DSH_SKIP_PLUGIN_INSTALL:-0}"
BACKUP_DIR="${DSH_BACKUP_DIR:-$HOME/dsh_backups}"
LOG_FILE="$HOME/dsh_$(date +%Y%m%d_%H%M%S).log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------- Утилиты ----------
log()  { echo -e "$1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}$1${NC}" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}$1${NC}" | tee -a "$LOG_FILE"; }
fail() { echo -e "${RED}$1${NC}" | tee -a "$LOG_FILE"; }
info() { echo -e "${CYAN}$1${NC}" | tee -a "$LOG_FILE"; }

die() { fail "$1"; echo ""; fail "Полный лог: $LOG_FILE"; exit 1; }

pause_return() { echo ""; read -rp "Нажмите Enter, чтобы вернуться в меню..." _ || true; }

port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -q ":${port} "; return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -q ":${port} "; return $?
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1
}

wait_for_port() {
    local port="$1" timeout="${2:-60}" i=0
    while ! port_listening "$port"; do
        i=$((i + 1))
        [ $i -ge "$timeout" ] && return 1
        sleep 1
        if [ $((i % 10)) -eq 0 ]; then warn "  Ожидание... ${i}s"; fi
    done
    return 0
}

kill_port() {
    local port="$1" pid
    for pid in $(ss -tulpn 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u); do
        sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    done
    sleep 2
}

systemd_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && return 0
    systemctl is-system-running >/dev/null 2>&1
}

get_service_logs() {
    local lines="${1:-200}"
    if systemd_active && systemctl is-active --quiet dsh 2>/dev/null; then
        sudo journalctl -u dsh -n "$lines" --no-pager 2>/dev/null || true
    elif [ -f "$HOME/dsh.log" ]; then
        tail -n "$lines" "$HOME/dsh.log" 2>/dev/null || true
    fi
}

detect_lan_ip() {
    local ip=""
    if command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
            | grep -Ev '^(127\.|169\.254\.|::1$|fe80)' | grep -E '\.' | head -1 || true)"
        [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    [ -z "$ip" ] && ip="<не удалось определить>"
    echo "$ip"
}

# =============================================================================
#  ПОКАЗ URL С ТОКЕНОМ
# =============================================================================
show_token_url() {
    echo ""
    info "🔑 URL для входа с токеном"
    echo ""

    local token=""
    token="$(get_service_logs 500 | grep -oP 'token=\K[A-Za-z0-9._-]+' | tail -1 || true)"

    if [ -z "$token" ]; then
        warn "Токен не найден в логах сервиса."
        echo ""
        read -rp "Перезапустить сервис dsh для свежего токена? [Y/n]: " ans
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            if systemd_active; then
                sudo systemctl restart dsh
                if wait_for_port "$DSH_PORT" 60; then
                    sleep 2
                    token="$(get_service_logs 500 | grep -oP 'token=\K[A-Za-z0-9._-]+' | tail -1 || true)"
                else
                    warn "Сервис не поднялся за 60s"; return 1
                fi
            else
                warn "systemd недоступен — перезапустите dsh вручную"; return 1
            fi
        fi
    fi

    if [ -z "$token" ]; then
        fail "Токен не найден. Проверьте логи вручную:"
        echo "  sudo journalctl -u dsh -n 100 | grep -i token"
        return 1
    fi

    local LAN_IP; LAN_IP="$(detect_lan_ip)"
    local url_lan="http://${LAN_IP}:${DSH_PORT}/?token=${token}"
    local url_loc="http://127.0.0.1:${DSH_PORT}/?token=${token}"

    echo ""
    echo -e "${BOLD}Скопируйте и откройте в браузере:${NC}"
    echo ""
    echo -e "  ${GREEN}${url_lan}${NC}"
    echo ""
    echo -e "Для входа на самом сервере:"
    echo -e "  ${CYAN}${url_loc}${NC}"
    echo ""
    warn "⚠️  Токен одноразовый — после первого успешного входа он сгорает."
    warn "   Браузер сохранит cookie на ~30 дней, дальше можно открывать"
    warn "   просто http://${LAN_IP}:${DSH_PORT}/ без токена."
    echo ""

    read -rp "Перезапустить сервис для свежего токена? [y/N]: " ans2
    if [[ "$ans2" =~ ^[Yy]$ ]]; then
        if systemd_active; then
            sudo systemctl restart dsh
            if wait_for_port "$DSH_PORT" 60; then
                sleep 2
                local new_token
                new_token="$(get_service_logs 500 | grep -oP 'token=\K[A-Za-z0-9._-]+' | tail -1 || true)"
                if [ -n "$new_token" ]; then
                    echo ""
                    ok "Свежий токен:"
                    echo ""
                    echo -e "  ${GREEN}http://${LAN_IP}:${DSH_PORT}/?token=${new_token}${NC}"
                    echo ""
                fi
            else
                warn "Сервис не поднялся за 60s"
            fi
        fi
    fi
}

# =============================================================================
#  БЭКАП / ВОССТАНОВЛЕНИЕ
# =============================================================================
create_backup() {
    local label="${1:-manual}"
    mkdir -p "$BACKUP_DIR"
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    local out="$BACKUP_DIR/dsh_backup_${ts}_${label}.tar.gz"

    local items=()
    [ -d "$HOME/.dsh" ] && items+=(".dsh")
    [ -d "$HOME/dsh-workspace" ] && items+=("dsh-workspace")

    if [ ${#items[@]} -eq 0 ]; then
        warn "Нечего бэкапить — нет ~/.dsh и ~/dsh-workspace"
        return 1
    fi

    if tar -czf "$out" -C "$HOME" "${items[@]}" 2>>"$LOG_FILE"; then
        ok "✅ Бэкап создан: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
        echo "$out"
        return 0
    fi
    fail "Не удалось создать бэкап"
    return 1
}

list_backups() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
        return 1
    fi
    ls -1t "$BACKUP_DIR"/dsh_backup_*.tar.gz 2>/dev/null
}

restore_backup_interactive() {
    echo ""
    info "♻️  Восстановление из бэкапа"
    echo ""

    local backups=()
    while IFS= read -r b; do backups+=("$b"); done < <(list_backups)

    if [ ${#backups[@]} -eq 0 ]; then
        warn "Бэкапы не найдены в $BACKUP_DIR"
        return 1
    fi

    echo "Доступные бэкапы (папка $BACKUP_DIR):"
    echo ""
    local i=1
    for b in "${backups[@]}"; do
        local size date_h
        size=$(du -h "$b" 2>/dev/null | cut -f1)
        date_h=$(date -r "$b" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
        printf "  ${GREEN}%2d)${NC} %s  [%s, %s]\n" "$i" "$(basename "$b")" "$date_h" "$size"
        i=$((i+1))
    done
    echo "  ${GREEN} 0)${NC} Отмена"
    echo ""
    read -rp "Выберите бэкап [0-${#backups[@]}]: " sel || return 1

    if [ "$sel" = "0" ] || [ -z "$sel" ]; then info "Отменено."; return 0; fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#backups[@]}" ]; then
        warn "Неверный выбор"; return 1
    fi

    local chosen="${backups[$((sel-1))]}"
    echo ""
    warn "Будет восстановлен: $(basename "$chosen")"
    echo "Текущее состояние ~/.dsh и ~/dsh-workspace будет ПЕРЕЗАПИСАНО."
    read -rp "Продолжить? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && { info "Отменено."; return 0; }

    log "Остановка сервиса..."
    if systemd_active; then
        sudo systemctl stop dsh 2>/dev/null || true
    fi
    if port_listening "$DSH_PORT"; then
        kill_port "$DSH_PORT"
    fi
    pkill -f "deepseek-ai/dsh" 2>/dev/null || true
    sleep 1

    log "Страховочный бэкап текущего состояния..."
    create_backup "before_restore" >/dev/null || warn "Страховочный бэкап не создан"

    [ -d "$HOME/.dsh" ] && sudo rm -rf "$HOME/.dsh"
    [ -d "$HOME/dsh-workspace" ] && sudo rm -rf "$HOME/dsh-workspace"

    log "Распаковка..."
    if ! tar -xzf "$chosen" -C "$HOME" 2>>"$LOG_FILE"; then
        die "Не удалось распаковать бэкап"
    fi

    [ -d "$HOME/.dsh" ] && sudo chown -R "$USER:$USER" "$HOME/.dsh" 2>/dev/null || true
    [ -d "$HOME/dsh-workspace" ] && sudo chown -R "$USER:$USER" "$HOME/dsh-workspace" 2>/dev/null || true

    ok "✅ Данные восстановлены из $(basename "$chosen")"

    if systemd_active && [ -f /etc/systemd/system/dsh.service ]; then
        log "Перезапуск сервиса..."
        sudo systemctl start dsh 2>/dev/null || true
        if wait_for_port "$DSH_PORT" 60; then
            ok "✅ Сервис dsh снова активен"
        else
            warn "Сервис не поднялся — проверьте: sudo journalctl -u dsh -n 100"
        fi
    fi

    return 0
}

# =============================================================================
#  УСТАНОВКА / ОБНОВЛЕНИЕ
# =============================================================================
run_install() {
    local mode="$1"

    echo ""
    if [ "$mode" = "update" ]; then
        info "🔄 Обновление DeepSeek Harness (с бэкапом)"
    else
        info "📦 Установка DeepSeek Harness (последняя версия)"
    fi
    echo ""

    if [ "$mode" = "update" ]; then
        if [ -d "$HOME/.dsh" ] || [ -d "$HOME/dsh-workspace" ]; then
            log "Создание бэкапа перед обновлением..."
            create_backup "before_update" >/dev/null || warn "Бэкап не создан (продолжаю)"
        else
            info "Данных для бэкапа нет — установка с нуля."
        fi
    fi

    log "${BLUE}[1/9] Определение LAN IP...${NC}"
    LAN_IP="$(detect_lan_ip)"
    log "LAN IP: ${GREEN}$LAN_IP${NC}"

    log "${BLUE}[2/9] GitHub → known_hosts...${NC}"
    mkdir -p ~/.ssh
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
    ok "GitHub добавлен"

    log "${BLUE}[3/9] Проверка Node.js...${NC}"
    local NODE_OK=0 NODE_VER="" NODE_MAJOR=0 NODE_MINOR=0
    if command -v node >/dev/null 2>&1; then
        NODE_VER="$(node --version)"
        NODE_MAJOR="$(echo "$NODE_VER" | sed -E 's/v([0-9]+).*/\1/')"
        NODE_MINOR="$(echo "$NODE_VER" | sed -E 's/v[0-9]+\.([0-9]+).*/\1/')"
        if [ "$NODE_MAJOR" -ge 24 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -ge 19 ]; }; then
            NODE_OK=1
        fi
    fi
    if [ "$NODE_OK" -eq 1 ]; then
        ok "Node.js: $NODE_VER (OK)"
    else
        if command -v node >/dev/null 2>&1; then
            warn "Node.js $NODE_VER не подходит (нужно ^22.19 || >=24). Обновляю..."
        else
            log "Node.js не найден. Устанавливаю Node 24 LTS..."
        fi
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - \
            || die "Не удалось добавить NodeSource"
        sudo apt-get install -y nodejs || die "Не удалось установить Node.js"
        ok "Node.js установлен: $(node --version)"
    fi

    log "${BLUE}[4/9] Проверка pnpm...${NC}"
    if ! command -v pnpm >/dev/null 2>&1; then
        log "Устанавливаю pnpm..."
        sudo npm install -g pnpm || die "Не удалось установить pnpm"
    fi
    ok "pnpm: $(pnpm --version)"

    log "${BLUE}[5/9] Установка @deepseek-ai/dsh@latest...${NC}"
    sudo npm install -g @deepseek-ai/dsh@latest --no-fund --no-audit 2>&1 | tee -a "$LOG_FILE" \
        || die "Не удалось установить dsh"

    hash -r 2>/dev/null || true
    local DSH_BIN; DSH_BIN="$(command -v dsh || true)"
    if [ -z "$DSH_BIN" ]; then
        die "dsh не найден в PATH после установки"
    fi
    local DSH_REAL; DSH_REAL="$(readlink -f "$DSH_BIN")"
    local DSH_VERSION; DSH_VERSION="$("$DSH_REAL" --version 2>/dev/null || echo "?")"
    ok "dsh: $DSH_VERSION (путь: $DSH_BIN → $DSH_REAL)"

    # Корректная проверка версии с учётом -rc.* суффиксов
    local DSH_MAJOR DSH_MINOR DSH_PATCH
    DSH_MAJOR="$(echo "$DSH_VERSION" | sed -E 's/^([0-9]+)\..*/\1/')"
    DSH_MINOR="$(echo "$DSH_VERSION" | sed -E 's/^[0-9]+\.([0-9]+).*/\1/')"
    DSH_PATCH="$(echo "$DSH_VERSION" | sed -E 's/^[0-9]+\.[0-9]+\.([0-9]+).*/\1/')"
    DSH_MAJOR="${DSH_MAJOR:-0}"; DSH_MINOR="${DSH_MINOR:-0}"; DSH_PATCH="${DSH_PATCH:-0}"
    if [ "$DSH_MAJOR" -eq 0 ] && { [ "$DSH_MINOR" -lt 1 ] || \
       { [ "$DSH_MINOR" -eq 1 ] && [ "$DSH_PATCH" -lt 5 ]; }; }; then
        warn "Версия $DSH_VERSION старше 0.1.5 — рекомендуется обновиться."
    fi

    log "${BLUE}[6/9] Установка плагина dsh-web-lan-access...${NC}"
    if [ "$SKIP_PLUGIN_INSTALL" -eq 1 ]; then
        warn "Пропускаю установку плагина (DSH_SKIP_PLUGIN_INSTALL=1)"
    else
        local PLUGIN_OK=0
        if dsh plugin --profile web add dsh-web-lan-access >> "$LOG_FILE" 2>&1; then
            PLUGIN_OK=1; ok "Плагин установлен из npm"
        elif dsh plugin --profile web add github:AcidGr/dsh-web-lan-access >> "$LOG_FILE" 2>&1; then
            PLUGIN_OK=1; ok "Плагин установлен из GitHub"
        fi
        if [ "$PLUGIN_OK" -eq 1 ] && dsh plugin --profile web list 2>/dev/null | grep -q "lan-access"; then
            ok "✅ Плагин dsh-web-lan-access активен"
        elif [ "$PLUGIN_OK" -eq 0 ]; then
            fail "❌ Плагин не установлен — LAN-доступ не будет работать"
            warn "   Установите вручную: dsh plugin --profile web add dsh-web-lan-access"
        fi
    fi

    log "${BLUE}[7/9] Права на папки...${NC}"
    for d in "$HOME/.dsh" "$HOME/dsh-workspace"; do
        if [ -d "$d" ]; then
            sudo chown -R "$USER:$USER" "$d" 2>/dev/null || true
            ok "Права: $d"
        fi
    done

    log "${BLUE}[8/9] Остановка старых сервисов...${NC}"
    if systemd_active; then
        for svc in dsh caddy-proxy caddy-https; do
            sudo systemctl stop "$svc" 2>/dev/null || true
            sudo systemctl disable "$svc" 2>/dev/null || true
        done
        sudo rm -f /etc/systemd/system/dsh.service
        sudo systemctl daemon-reload 2>/dev/null || true
    fi
    if port_listening "$DSH_PORT"; then
        warn "Порт $DSH_PORT занят — останавливаю..."
        kill_port "$DSH_PORT"
    fi
    ok "Старые сервисы остановлены"

    log "${BLUE}[9/9] systemd-сервис...${NC}"
    local ENV_KEY_LINE=""
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        ENV_KEY_LINE="Environment=\"DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY\""
        log "DEEPSEEK_API_KEY будет прописан в сервис"
    fi

    if systemd_active; then
        sudo tee /etc/systemd/system/dsh.service > /dev/null << EOF
[Unit]
Description=DeepSeek Harness Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
Environment="HOME=$HOME"
Environment="USER=$USER"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
$ENV_KEY_LINE
ExecStart=$(command -v dsh) web --port $DSH_PORT --no-open
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dsh

[Install]
WantedBy=multi-user.target
EOF

        ok "Сервис создан (порт $DSH_PORT, без --patch)"
        sudo systemctl daemon-reload
        sudo systemctl reset-failed dsh 2>/dev/null || true
        sudo systemctl enable dsh 2>&1 | tee -a "$LOG_FILE" || warn "enable не сработал"
        sudo systemctl start dsh || warn "start не сработал"
        if sudo systemctl is-active --quiet dsh; then
            ok "✅ Сервис активен"
        else
            warn "⚠️  Сервис не активен: sudo journalctl -u dsh -n 50"
        fi

        log "Ожидание порта $DSH_PORT..."
        if ! wait_for_port "$DSH_PORT" 90; then
            die "Таймаут: dsh не запустился. Лог: sudo journalctl -u dsh -f"
        fi
        ok "✅ dsh готов"
    else
        warn "systemd не найден — запуск через nohup"
        nohup "$(command -v dsh)" web --port "$DSH_PORT" --no-open \
            >> "$HOME/dsh.log" 2>&1 &
        disown
        if ! wait_for_port "$DSH_PORT" 90; then
            die "Таймаут: dsh не запустился. Смотрите $HOME/dsh.log"
        fi
        ok "✅ dsh готов (лог: $HOME/dsh.log)"
    fi

    # --- Проверка результата (без сжигания токена!) ---
    echo ""
    log "${BLUE}Проверка результата...${NC}"
    sleep 3

    local SERVICE_LOGS; SERVICE_LOGS="$(get_service_logs 300)"
    local AUTH_TOKEN=""
    AUTH_TOKEN="$(echo "$SERVICE_LOGS" | grep -oP 'token=\K[A-Za-z0-9._-]+' | tail -1 || true)"

    local BASE_URL="http://127.0.0.1:${DSH_PORT}"

    # 1. Проверка доступности (401 = сервер работает, требует токен)
    local CODE
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$BASE_URL/" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        ok "✅ Веб-интерфейс отвечает (HTTP $CODE)"
    elif [ "$CODE" = "401" ]; then
        ok "✅ Веб-интерфейс отвечает (HTTP 401 — требуется токен)"
    else
        fail "❌ Веб не отвечает (HTTP $CODE)"
    fi

    # 2. Токен готов — НЕ проверяем, чтобы не сжечь
    if [ -n "$AUTH_TOKEN" ]; then
        local LAN_IP_T; LAN_IP_T="$(detect_lan_ip)"
        info "🔑 Токен для входа получен. Откройте:"
        echo -e "   ${GREEN}http://${LAN_IP_T}:${DSH_PORT}/?token=${AUTH_TOKEN}${NC}"
        info "   (пункт меню 5 — показать снова или обновить токен)"
    else
        warn "⚠️  Токен не найден — sudo journalctl -u dsh -n 50 | grep token"
    fi

    # 3. Привилегированные методы из LAN (не требует токена — важна проверка 403/401)
    local LAN_HOST="${LAN_IP}:${DSH_PORT}"
    local PRIV_CODE
    PRIV_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
        -H "Host: $LAN_HOST" -H "Content-Type: application/json" \
        -d '{"type":"client-request","rpcId":"chk","method":"settings.describe","payload":{}}' \
        "$BASE_URL/api/settings.describe" 2>/dev/null || echo 000)"
    if [ "$PRIV_CODE" = "401" ] || [ "$PRIV_CODE" = "200" ]; then
        ok "✅ Settings из LAN (Host=$LAN_HOST): HTTP $PRIV_CODE"
    elif [ "$PRIV_CODE" != "403" ] && [ "$PRIV_CODE" != "000" ]; then
        ok "✅ Settings из LAN: HTTP $PRIV_CODE (не 403)"
    else
        fail "❌ Settings из LAN: HTTP $PRIV_CODE (нужен плагин lan-access)"
    fi

    # 4. Внешние хосты
    local EXT_CODE
    EXT_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
        -H "Host: dsh-check.invalid:${DSH_PORT}" \
        -d '{}' "$BASE_URL/api/settings.describe" 2>/dev/null || echo 000)"
    if [ "$EXT_CODE" = "403" ]; then
        ok "✅ Внешние хосты блокируются (403)"
    else
        warn "⚠️  Внешний хост вернул $EXT_CODE (ожидалось 403)"
    fi

    # 5. Плагин
    if dsh plugin --profile web list 2>/dev/null | grep -q "lan-access"; then
        ok "✅ Плагин dsh-web-lan-access активен"
    else
        fail "❌ Плагин dsh-web-lan-access не активен"
    fi

    echo ""
    ok "🎉 Установка/обновление завершено"
    echo ""
    if [ -n "$AUTH_TOKEN" ]; then
        echo -e "🌐 ${BOLD}Войти с другого устройства:${NC}"
        echo -e "   ${GREEN}http://${LAN_IP}:${DSH_PORT}/?token=${AUTH_TOKEN}${NC}"
    else
        echo -e "🌐 Открыть: ${GREEN}http://$LAN_IP:${DSH_PORT}${NC}"
    fi
    echo -e "   (пункт меню 5 — показать токен снова / обновить)"
    echo ""
    echo -e "   Settings → Models → введите API-ключ DeepSeek → выберите модель"
    echo -e "   Управление: ${YELLOW}sudo systemctl status|restart|stop dsh${NC}"
    echo -e "   Логи:       ${YELLOW}sudo journalctl -u dsh -f${NC}"
    if [ "$mode" = "update" ]; then
        echo ""
        echo -e "💾 Бэкап перед обновлением: ${CYAN}$BACKUP_DIR${NC}"
    fi
}

# =============================================================================
#  ПОЛНОЕ УДАЛЕНИЕ
# =============================================================================
uninstall_dsh() {
    echo ""
    warn "🗑  ПОЛНОЕ УДАЛЕНИЕ DeepSeek Harness"
    echo ""
    echo "Будет удалено:"
    echo "  • systemd-сервисы: dsh, caddy-proxy, caddy-https"
    echo "  • npm/pnpm пакет @deepseek-ai/dsh (во всех найденных местах)"
    echo "  • бинарники dsh, симлинки"
    echo "  • запущенные процессы dsh (порт $DSH_PORT)"
    echo ""
    read -rp "Продолжить удаление? [y/N]: " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && { info "Отменено."; return 0; }

    echo ""
    log "── Остановка сервисов ──"
    if systemd_active; then
        for svc in dsh caddy-proxy caddy-https; do
            sudo systemctl stop "$svc" 2>/dev/null && ok "stop $svc" || true
            sudo systemctl disable "$svc" 2>/dev/null && ok "disable $svc" || true
        done
        sudo rm -f /etc/systemd/system/dsh.service \
                    /etc/systemd/system/caddy-proxy.service \
                    /etc/systemd/system/caddy-https.service
        sudo systemctl daemon-reload 2>/dev/null || true
        ok "Юнит-файлы удалены"
    fi

    log "── Остановка процессов ──"
    if port_listening "$DSH_PORT"; then
        kill_port "$DSH_PORT"
    fi
    pkill -f "deepseek-ai/dsh" 2>/dev/null && ok "Процессы dsh убиты" || true
    pkill -f "dsh web" 2>/dev/null && ok "Процессы 'dsh web' убиты" || true
    sleep 1

    log "── Удаление npm/pnpm пакетов ──"
    if command -v npm >/dev/null 2>&1; then
        sudo npm uninstall -g @deepseek-ai/dsh 2>&1 | tee -a "$LOG_FILE" || true
    fi
    if command -v pnpm >/dev/null 2>&1; then
        sudo pnpm remove -g @deepseek-ai/dsh 2>&1 | tee -a "$LOG_FILE" || true
    fi

    log "── Поиск и удаление остатков ──"
    local paths=(
        /usr/lib/node_modules/@deepseek-ai/dsh
        /usr/local/lib/node_modules/@deepseek-ai/dsh
        "$HOME/.local/share/pnpm/global"/*/node_modules/@deepseek-ai/dsh
        "$HOME/.npm-global/lib/node_modules/@deepseek-ai/dsh"
    )
    for p in "${paths[@]}"; do
        if [ -d "$p" ]; then
            sudo rm -rf "$p" && ok "Удалено: $p"
        fi
    done

    for root in /usr/lib/node_modules /usr/local/lib/node_modules "$HOME/.local/share/pnpm"; do
        [ -d "$root" ] || continue
        while IFS= read -r hit; do
            [ -n "$hit" ] && sudo rm -rf "$hit" && ok "Удалено: $hit"
        done < <(find "$root" -maxdepth 4 -type d -name dsh -path '*@deepseek-ai*' 2>/dev/null)
    done

    log "── Удаление бинарников ──"
    for b in /usr/bin/dsh /usr/local/bin/dsh "$HOME/.local/bin/dsh" "$HOME/bin/dsh"; do
        if [ -e "$b" ] || [ -L "$b" ]; then
            sudo rm -f "$b" && ok "Удалён: $b"
        fi
    done
    hash -r 2>/dev/null || true

    if command -v dsh >/dev/null 2>&1; then
        warn "⚠️  dsh всё ещё в PATH: $(command -v dsh)"
    else
        ok "✅ Бинарник dsh больше не найден"
    fi

    echo ""
    log "── Пользовательские данные ──"
    local has_data=0
    [ -d "$HOME/.dsh" ] && { echo "  • $HOME/.dsh"; has_data=1; }
    [ -d "$HOME/dsh-workspace" ] && { echo "  • $HOME/dsh-workspace"; has_data=1; }
    [ -f "$HOME/dsh.log" ] && { echo "  • $HOME/dsh.log"; has_data=1; }

    if [ "$has_data" -eq 1 ]; then
        echo ""
        warn "Удаление приведёт к потере настроек, ключей, чатов и workspaces."
        read -rp "Удалить пользовательские данные? [y/N]: " ans2
        if [[ "$ans2" =~ ^[Yy]$ ]]; then
            read -rp "Создать бэкап перед удалением? [Y/n]: " ans3
            if [[ ! "$ans3" =~ ^[Nn]$ ]]; then
                create_backup "before_uninstall" >/dev/null || warn "Бэкап не создан"
            fi
            [ -d "$HOME/.dsh" ] && sudo rm -rf "$HOME/.dsh" && ok "Удалено: $HOME/.dsh"
            [ -d "$HOME/dsh-workspace" ] && sudo rm -rf "$HOME/dsh-workspace" && ok "Удалено: $HOME/dsh-workspace"
            [ -f "$HOME/dsh.log" ] && rm -f "$HOME/dsh.log" && ok "Удалён: $HOME/dsh.log"
        else
            info "Пользовательские данные сохранены."
        fi
    else
        info "Пользовательских данных не найдено."
    fi

    echo ""
    ok "✅ Удаление завершено."
    if ls "$BACKUP_DIR"/dsh_backup_*.tar.gz >/dev/null 2>&1; then
        echo -e "💾 Сохранённые бэкапы: ${CYAN}$BACKUP_DIR${NC}"
    fi
}

# =============================================================================
#  МЕНЮ И DISPATCH
# =============================================================================
show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   DeepSeek Harness Manager  v${SCRIPT_VERSION}                  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Пользователь: ${GREEN}$USER${NC}   HOME: ${GREEN}$HOME${NC}"
    echo -e "  Порт: ${GREEN}$DSH_PORT${NC}   Бэкапы: ${GREEN}$BACKUP_DIR${NC}"
    echo -e "  Лог: ${GREEN}$LOG_FILE${NC}"
    echo ""
    local dsh_state="не установлен"
    if command -v dsh >/dev/null 2>&1; then
        dsh_state="установлен ($(dsh --version 2>/dev/null || echo '?'))"
    fi
    local svc_state="—"
    if systemd_active && systemctl is-active --quiet dsh 2>/dev/null; then
        svc_state="${GREEN}active${NC}"
    elif systemd_active && systemctl list-unit-files 2>/dev/null | grep -q '^dsh.service'; then
        svc_state="${YELLOW}inactive${NC}"
    fi
    echo -e "  dsh: ${GREEN}$dsh_state${NC}   Сервис: $svc_state"
    echo ""
    echo -e "  ${GREEN}1)${NC} 🗑  Удалить DSH (полное удаление)"
    echo -e "  ${GREEN}2)${NC} 📦 Установить последнюю версию DSH"
    echo -e "  ${GREEN}3)${NC} 🔄 Обновить DSH (с бэкапом)"
    echo -e "  ${GREEN}4)${NC} ♻️  Восстановить из Backup"
    echo -e "  ${GREEN}5)${NC} 🔑 Показать URL для входа (с токеном)"
    echo -e "  ${GREEN}0)${NC} 🚪 Выход"
    echo ""
}

menu_loop() {
    while true; do
        show_menu
        read -rp "Выбор [0-5]: " choice || exit 0
        case "$choice" in
            1) uninstall_dsh; pause_return ;;
            2) run_install "install"; pause_return ;;
            3) run_install "update"; pause_return ;;
            4) restore_backup_interactive; pause_return ;;
            5) show_token_url; pause_return ;;
            0) echo ""; ok "До встречи!"; exit 0 ;;
            *) warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ---------- Точка входа ----------
case "${1:-}" in
    install)   run_install "install" ;;
    update)    run_install "update" ;;
    uninstall) uninstall_dsh ;;
    restore)   restore_backup_interactive ;;
    token|url) show_token_url ;;
    ""|menu)   menu_loop ;;
    -h|--help)
        echo "Usage: $0 [install|update|uninstall|restore|token]"
        echo "Без аргументов — интерактивное меню."
        ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
esac

exit 0
