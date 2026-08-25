#!/bin/bash
# =============================================================================
#  Диагностика и исправление DeepSeek Harness (dsh) + Remote/LAN access
#  Версия 2.2 — исправлена автозагрузка systemd (сервис стартует при загрузке)
#
#  Что нового в v2.2:
#   - После создания systemd-юнита явно проверяется включение (enable) и статус.
#   - При ошибке старта выводятся команды для ручной диагностики.
#   - Сообщения стали более информативными.
#
#  Полный список функций — см. комментарии в начале скрипта.
# =============================================================================

set -euo pipefail

# ---------- Настройки ----------
DSH_PORT="${DSH_PORT:-3080}"
SKIP_PRIVILEGED_PATCH="${DSH_SKIP_PRIVILEGED_PATCH:-0}"   # 1 = не патчить шлюз
FORCE_DSH_REINSTALL="${DSH_FORCE_REINSTALL:-0}"           # 1 = переустановить dsh
OVERLAY_FILE="$HOME/.dsh/overlays/lan.yml"
LOG_FILE="$HOME/dsh_fix_$(date +%Y%m%d_%H%M%S).log"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ---------- Утилиты ----------
log()  { echo -e "$1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}$1${NC}" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}$1${NC}" | tee -a "$LOG_FILE"; }
fail() { echo -e "${RED}$1${NC}" | tee -a "$LOG_FILE"; }

die() {
    fail "$1"
    echo ""
    fail "Полный лог: $LOG_FILE"
    exit 1
}

# Слушает ли что-то порт
port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -q ":${port} "
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -q ":${port} "
        return $?
    fi
    # крайний случай — без внешних утилит
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
        kill "$pid" 2>/dev/null || true
    done
    sleep 2
}

# ---------- Шапка ----------
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  Диагностика и исправление DeepSeek      ${NC}"
echo -e "${BLUE}  Harness + Remote Access (v2.2)         ${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo "Лог сохраняется в: $LOG_FILE"
echo ""

# ---------- 0. Определение пользователя ----------
log "${BLUE}[0/12] Проверка пользователя...${NC}"
if [ "$EUID" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ]; then
        RUN_USER="$SUDO_USER"
        RUN_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        log "Запущено через sudo; сервис будет работать от ${GREEN}$RUN_USER${NC} (home: $RUN_HOME)"
    else
        warn "Скрипт запущен от root напрямую. Рекомендуется запускать от обычного пользователя"
        warn "(sudo ./dsh_fix.sh). Продолжаю от root — всё будет в /root/.dsh."
        RUN_USER="root"; RUN_HOME="$HOME"
    fi
else
    RUN_USER="$USER"; RUN_HOME="$HOME"
fi
# Дальше в скрипте $USER/$HOME должны указывать на реального пользователя
export HOME="$RUN_HOME"; export USER="$RUN_USER"

# ---------- 1. Определение LAN IP (раньше, чтобы использовать в проверках) ----------
log "${BLUE}[1/12] Определение IP-адреса...${NC}"
if command -v hostname >/dev/null 2>&1; then
    # берём первый приватный IPv4 (исключаем loopback и link-local 169.254.x.x)
    LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -Ev '^(127\.|169\.254\.|::1$|fe80)' | grep -E '\.' | head -1 || true)"
    [ -z "$LAN_IP" ] && LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
[ -z "${LAN_IP:-}" ] && LAN_IP="<не удалось определить>"
log "LAN IP: ${GREEN}$LAN_IP${NC}"

# ---------- 2. GitHub в known_hosts ----------
log "${BLUE}[2/12] Добавление GitHub в known_hosts...${NC}"
mkdir -p ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
ok "GitHub добавлен в known_hosts"

# ---------- 3. Node.js (dsh требует ^22.19 || >=24) ----------
log "${BLUE}[3/12] Проверка Node.js...${NC}"
NODE_OK=0
if command -v node >/dev/null 2>&1; then
    NODE_VER="$(node --version)"
    NODE_MAJOR="$(echo "$NODE_VER" | sed -E 's/v([0-9]+).*/\1/')"
    NODE_MINOR="$(echo "$NODE_VER" | sed -E 's/v[0-9]+\.([0-9]+).*/\1/')"
    if [ "$NODE_MAJOR" -ge 24 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -ge 19 ]; }; then
        NODE_OK=1
    fi
fi

if [ "$NODE_OK" -eq 1 ]; then
    ok "Node.js: $NODE_VER (поддерживается)"
else
    if command -v node >/dev/null 2>&1; then
        warn "Node.js $(node --version) НЕ поддерживается dsh (нужно ^22.19 || >=24). Обновляю..."
    else
        log "Node.js не найден. Устанавливаю Node 24 LTS..."
    fi
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - \
        || die "Не удалось добавить репозиторий NodeSource"
    sudo apt-get install -y nodejs || die "Не удалось установить Node.js"
    ok "Node.js установлен: $(node --version)"
fi

# sanity: crypto.randomUUID доступен в node (есть с 16.7+/19+)
if node -e "process.exit(typeof crypto.randomUUID === 'function' ? 0 : 1)" 2>/dev/null; then
    ok "crypto.randomUUID в Node — OK"
else
    fail "В Node нет crypto.randomUUID. Проверьте установку Node."
fi

# ---------- 4. pnpm (нужен для dsh plugin) ----------
log "${BLUE}[4/12] Проверка pnpm...${NC}"
if ! command -v pnpm >/dev/null 2>&1; then
    log "pnpm не найден. Устанавливаю..."
    sudo npm install -g pnpm || die "Не удалось установить pnpm"
fi
ok "pnpm: $(pnpm --version)"

# ---------- 5. dsh ----------
log "${BLUE}[5/12] Проверка dsh...${NC}"
DSH_BIN="$(command -v dsh || true)"
DSH_VER_OK=0
if [ -n "$DSH_BIN" ] && dsh --version >/dev/null 2>&1; then
    DSH_VER_OK=1
fi

if [ "$DSH_VER_OK" -eq 1 ] && [ "$FORCE_DSH_REINSTALL" -ne 1 ]; then
    ok "dsh найден: $DSH_BIN ($(dsh --version))"
else
    log "Устанавливаю/обновляю @deepseek-ai/dsh..."
    sudo npm install -g @deepseek-ai/dsh || die "Не удалось установить dsh"
    ok "dsh установлен: $(dsh --version)"
fi

# Путь к пакету (реальный путь, через readlink, на случай симлинков pnpm/npm)
DSH_BIN="$(readlink -f "$(command -v dsh)")"
DSH_PKG_DIR="$(dirname "$(dirname "$DSH_BIN")")"   # .../@deepseek-ai/dsh
log "Пакет dsh: $DSH_PKG_DIR"

# ---------- 6. LAN-оверлей ----------
log "${BLUE}[6/12] Проверка LAN-оверлея...${NC}"
mkdir -p "$(dirname "$OVERLAY_FILE")"
if [ ! -f "$OVERLAY_FILE" ]; then
    cat > "$OVERLAY_FILE" << EOF
- type: patch
  id: webserver
  config:
    host: 0.0.0.0
    port: $DSH_PORT
EOF
    ok "Оверлей создан: $OVERLAY_FILE"
else
    ok "Оверлей найден: $OVERLAY_FILE"
fi

# ---------- 7. Права на папки ----------
log "${BLUE}[7/12] Исправление прав доступа...${NC}"
for d in "$HOME/.dsh" "$HOME/dsh-workspace"; do
    if [ -d "$d" ]; then
        sudo chown -R "$USER:$USER" "$d" 2>/dev/null || true
        ok "Права на $d исправлены"
    fi
done

# ---------- 8. Остановка старых сервисов ----------
log "${BLUE}[8/12] Остановка старых сервисов и процессов...${NC}"
if command -v systemctl >/dev/null 2>&1; then
    for svc in dsh caddy-proxy caddy-https; do
        sudo systemctl stop "$svc" 2>/dev/null || true
        sudo systemctl disable "$svc" 2>/dev/null || true
    done
    sudo rm -f /etc/systemd/system/dsh.service
    sudo rm -f /etc/systemd/system/caddy-proxy.service
    sudo rm -f /etc/systemd/system/caddy-https.service
    sudo systemctl daemon-reload 2>/dev/null || true
fi
# добиваем всё, что висит на порту (например, dsh, запущенный вручную)
if port_listening "$DSH_PORT"; then
    warn "Порт $DSH_PORT занят — останавливаю процесс(ы)..."
    kill_port "$DSH_PORT"
fi
ok "Старые сервисы остановлены"

# ---------- 9. Установка плагина dsh-web-lan-access ----------
log "${BLUE}[9/12] Установка плагина dsh-web-lan-access...${NC}"
PLUGIN_OK=0
# npm-бандл (рекомендованный способ)
if dsh plugin --profile web add dsh-web-lan-access >> "$LOG_FILE" 2>&1; then
    PLUGIN_OK=1
    ok "Плагин установлен из npm (dsh-web-lan-access)"
else
    warn "Установка из npm не удалась. Пробую из GitHub (github:AcidGr/dsh-web-lan-access)..."
    if dsh plugin --profile web add github:AcidGr/dsh-web-lan-access >> "$LOG_FILE" 2>&1; then
        PLUGIN_OK=1
        ok "Плагин установлен из GitHub"
    fi
fi

if [ "$PLUGIN_OK" -eq 1 ]; then
    if dsh plugin --profile web list 2>/dev/null | grep -q "lan-access"; then
        ok "Плагин активен в профиле web"
    fi
else
    warn "⚠️  Плагин не установлен — по http://<LAN-IP> будет ошибка crypto.randomUUID."
    warn "    Можно установить вручную позже: dsh plugin --profile web add dsh-web-lan-access"
fi

# ---------- 10. Патч /api: сервер + клиент ----------
# У ошибки "settings are unavailable in this browser" ДВА независимых источника:
#
#  (1) СЕРВЕР: settings.*, credentials.*, llm.discoverModels привязаны к loopback
#      (isTrustedApiRequest(request, []) в dsh-client-connection/lib/index.js) —
#      из LAN они отдают 403.
#  (2) КЛИЕНТ (главный виновник ошибки в браузере): при открытии по LAN-IP
#      connection.isLoopback = false, и клиент сам переводит зеркало настроек
#      в режим "memory" (dsh-client-ui-settings: connection.isLoopback ?
#      "host" : "memory") — settings.describe вообще НЕ вызывается, view
#      остаётся пустым → "settings are unavailable in this browser".
#
# Патчим оба. Сначала сервер, потом клиент (в client.js одна точка —
# isLoopback: pageLocation === void 0 || isLoopbackHostname(...) -> isLoopback: true).
log "${BLUE}[10/12] Патч серверного шлюза /api...${NC}"

# Находит файлы dsh-client-connection в установленном пакете (npm/pnpm раскладка отличается)
find_dsh_conn_file() {
    local name="$1" search_dirs=("$DSH_PKG_DIR")
    [ -d /usr/lib/node_modules/@deepseek-ai ] && search_dirs+=(/usr/lib/node_modules/@deepseek-ai)
    [ -d /usr/local/lib/node_modules/@deepseek-ai ] && search_dirs+=(/usr/local/lib/node_modules/@deepseek-ai)
    [ -d "$HOME/.dsh/profiles" ] && search_dirs+=("$HOME/.dsh/profiles")
    find "${search_dirs[@]}" -path "*dsh-client-connection/lib/$name" -type f 2>/dev/null | head -1 || true
}

# Применить замену old -> new в файле с бэкапом и проверкой
apply_file_patch() {
    local file="$1" old="$2" new="$3" desc="$4"
    if grep -qF "$new" "$file"; then
        ok "Уже применено ($desc): $file"
        return 0
    fi
    if ! grep -qF "$old" "$file"; then
        fail "Не найдена ожидаемая строка ($desc). Возможно, другая версия dsh:"
        fail "  old=[$old]"
        return 1
    fi
    sudo cp "$file" "${file}.dshbak"
    if command -v python3 >/dev/null 2>&1; then
        sudo python3 - "$file" "$old" "$new" << PYEOF
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if old in s and new not in s:
    open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PYEOF
    else
        OLD="$old" NEW="$new" sudo perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
    fi
    if grep -qF "$new" "$file"; then
        ok "Применено ($desc): $file"
        ok "Резервная копия: ${file}.dshbak"
        return 0
    fi
    fail "Не удалось применить патч ($desc)."
    return 1
}

CONN_DIR="$(dirname "$(find_dsh_conn_file index.js)")"
SERVER_FILE="$CONN_DIR/index.js"
CLIENT_FILE="$CONN_DIR/client.js"

CLIENT_PATCH_OK=1

# --- (1) серверный патч ---
if [ "$SKIP_PRIVILEGED_PATCH" -eq 1 ]; then
    warn "Пропускаю серверный патч (DSH_SKIP_PRIVILEGED_PATCH=1). Settings → Models из LAN будет давать 403."
else
    echo -e "${YELLOW}⚠️  ВАЖНО (безопасность): патчи разрешают Settings / Credentials /${NC}"
    echo -e "${YELLOW}   Models для доверенных LAN-хостов. dsh НЕ имеет авторизации — любой в${NC}"
    echo -e "${YELLOW}   вашей сети сможет менять настройки агента. Используйте только в${NC}"
    echo -e "${YELLOW}   доверенной сети или ограничьте фаерволом, например:${NC}"
    echo -e "${YELLOW}   sudo ufw allow from 192.168.0.0/16 to any port ${DSH_PORT}${NC}"
    echo ""
    if [ -n "$SERVER_FILE" ] && apply_file_patch "$SERVER_FILE" \
        'PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, [])' \
        'PRIVILEGED_METHODS.has(method) && !isTrustedApiRequest(request, trustedHosts)' \
        'серверный шлюз /api'; then
        ok "Серверный шлюз /api пропускает привилегированные методы из LAN"
    else
        fail "Серверный патч не применён — Settings → Models из LAN будет давать 403."
    fi
fi

# --- (2) клиентский патч (без него браузер НЕ вызывает settings.describe из LAN) ---
log "${BLUE}[10b/12] Патч клиента (isLoopback для LAN)...${NC}"
if [ "${DSH_SKIP_CLIENT_PATCH:-0}" -eq 1 ]; then
    warn "Пропускаю клиентский патч (DSH_SKIP_CLIENT_PATCH=1). Настройка моделей — только с http://127.0.0.1:${DSH_PORT}"
else
    if [ -n "$CLIENT_FILE" ] && apply_file_patch "$CLIENT_FILE" \
        'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),' \
        'isLoopback: true,' \
        'клиент isLoopback'; then
        CLIENT_PATCH_OK=0
    else
        fail "Клиентский патч не применён — ошибка 'settings are unavailable in this browser' останется."
        CLIENT_PATCH_OK=1
    fi
fi

if [ "$CLIENT_PATCH_OK" -eq 0 ]; then
    ok "Клиент будет считать LAN-подключение доверенным: settings/credentials из LAN загрузятся"
fi

# ---------- 11. systemd-сервис (УЛУЧШЕННАЯ ВЕРСИЯ) ----------
log "${BLUE}[11/12] Создание systemd-сервиса для dsh...${NC}"

# systemd реально работает? (в контейнерах systemctl есть, но это не init)
systemd_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && return 0
    systemctl is-system-running >/dev/null 2>&1
}

# Опционально: ключ DeepSeek в окружении сервиса
ENV_KEY_LINE=""
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    ENV_KEY_LINE="Environment=\"DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY\""
    log "DEEPSEEK_API_KEY будет прописан в окружении сервиса (модель настроена сразу)"
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
ExecStart=$(command -v dsh) web --patch $OVERLAY_FILE --no-open
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dsh

[Install]
WantedBy=multi-user.target
EOF

    ok "Сервис dsh создан (/etc/systemd/system/dsh.service)"
    sudo systemctl daemon-reload
    sudo systemctl reset-failed dsh 2>/dev/null || true

    # Включаем автозапуск
    if sudo systemctl enable dsh 2>&1 | tee -a "$LOG_FILE"; then
        ok "✅ Сервис dsh включён в автозагрузку"
    else
        warn "⚠️  Не удалось включить автозапуск. Проверьте: sudo systemctl enable dsh"
    fi

    # Запускаем сейчас
    if sudo systemctl start dsh; then
        ok "Сервис dsh запущен"
    else
        warn "⚠️  Не удалось запустить dsh. Смотрите логи: sudo journalctl -u dsh -f"
    fi

    # Проверяем статус
    if sudo systemctl is-active --quiet dsh; then
        ok "✅ Сервис dsh активен"
    else
        warn "⚠️  Сервис dsh не активен. Проверьте статус: sudo systemctl status dsh"
    fi

    # Проверяем, что порт слушается
    log "Ожидание готовности dsh (порт $DSH_PORT)..."
    if ! wait_for_port "$DSH_PORT" 90; then
        die "Таймаут: dsh не запустился за 90 секунд. Смотрите: sudo journalctl -u dsh -f"
    fi
    ok "✅ dsh готов (порт $DSH_PORT слушается)"
else
    warn "systemd не найден — запускаю dsh в фоне через nohup (автозапуск не настроен)."
    nohup "$(command -v dsh)" web --patch "$OVERLAY_FILE" --no-open \
        >> "$HOME/dsh.log" 2>&1 &
    disown
    log "Ожидание готовности dsh (порт $DSH_PORT)..."
    if ! wait_for_port "$DSH_PORT" 90; then
        die "Таймаут: dsh не запустился. Лог: $HOME/dsh.log"
    fi
    ok "✅ dsh готов (порт $DSH_PORT слушается, лог: $HOME/dsh.log)"
fi

# ---------- 12. Проверка результата ----------
log "${BLUE}[12/12] Проверка результата...${NC}"
sleep 2
FAILS=0

# 12.1 index.html
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${DSH_PORT}/" 2>/dev/null || echo 000)"
if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
    ok "✅ Веб-интерфейс отвечает (HTTP $CODE)"
else
    fail "❌ Веб-интерфейс не отвечает (HTTP $CODE)"; FAILS=$((FAILS+1))
fi

# 12.2 полифилл crypto.randomUUID
if curl -s --max-time 5 "http://127.0.0.1:${DSH_PORT}/" 2>/dev/null | grep -q "lan-access-polyfill"; then
    ok "✅ Полифилл crypto.randomUUID инжектится в index.html"
else
    warn "⚠️  Полифилл не найден — возможна ошибка crypto.randomUUID с LAN-IP"
fi

# 12.3 привилегированные методы из LAN (бывшая ошибка "settings are unavailable")
# Проверяем и HTTP-код, и реальный JSON-RPC ответ (ok:true = браузер получит настройки)
LAN_HOST="${LAN_IP}:${DSH_PORT}"
PRIV_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H "Host: $LAN_HOST" -H "Content-Type: application/json" \
    -d '{"type":"client-request","rpcId":"chk","method":"settings.describe","payload":{}}' \
    "http://127.0.0.1:${DSH_PORT}/api/settings.describe" 2>/dev/null || echo 000)"
if [ "$PRIV_CODE" = "200" ]; then
    ok "✅ Settings/Models из LAN (Host=$LAN_HOST) — HTTP 200"
elif [ "$PRIV_CODE" != "403" ] && [ "$PRIV_CODE" != "000" ]; then
    ok "✅ Settings/Models из LAN (Host=$LAN_HOST) — не 403 (HTTP $PRIV_CODE)"
else
    fail "❌ Settings/Models из LAN всё ещё 403 (HTTP $PRIV_CODE)"; FAILS=$((FAILS+1))
fi

# 12.4 внешний хост по-прежнему заблокирован (безопасность)
EXT_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H "Host: dsh-check.invalid:${DSH_PORT}" \
    -d '{}' "http://127.0.0.1:${DSH_PORT}/api/settings.describe" 2>/dev/null || echo 000)"
if [ "$EXT_CODE" = "403" ]; then
    ok "✅ Внешние хосты по-прежнему блокируются (HTTP 403)"
else
    warn "⚠️  Внешний хост вернул HTTP $EXT_CODE (ожидался 403)"
fi

# 12.5 плагин в списке
if dsh plugin --profile web list 2>/dev/null | grep -q "lan-access"; then
    ok "✅ Плагин dsh-web-lan-access активен"
fi

# 12.6 ГЛАВНОЕ: что реально получает браузер — патченый клиентский код
SERVED_CONN="$(curl -s --max-time 5 "http://127.0.0.1:${DSH_PORT}/plugins/@deepseek-ai/dsh-client-connection/client.js" 2>/dev/null || true)"
if echo "$SERVED_CONN" | grep -q "isLoopback: true"; then
    ok "✅ Браузер получит клиент с isLoopback=true (Settings загрузятся из LAN)"
else
    fail "❌ Сервер отдаёт НЕпатченый клиент — ошибка 'settings are unavailable in this browser' останется"
    FAILS=$((FAILS+1))
fi

# ---------- Итоговый отчёт ----------
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}           УСТАНОВКА ЗАВЕРШЕНА          ${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "🌐 DeepSeek Harness доступен:"
echo -e "   ${GREEN}http://$LAN_IP:${DSH_PORT}${NC}  (с других устройств в сети)"
echo -e "   ${GREEN}http://127.0.0.1:${DSH_PORT}${NC}  (на самом сервере)"
echo ""

if [ "$FAILS" -eq 0 ]; then
    echo -e "✅ Чтобы выбрать модель:"
else
    echo -e "⚠️  Есть проблемы (см. выше). Чтобы выбрать модель:"
fi
echo -e "   1. Откройте ${GREEN}http://$LAN_IP:${DSH_PORT}${NC} в браузере"
echo -e "   2. ${YELLOW}Settings → Models${NC}"
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    echo -e "   3. Ключ уже прописан (DEEPSEEK_API_KEY) — модель доступна сразу"
else
    echo -e "   3. Введите API-ключ DeepSeek (platform.deepseek.com) — поле теперь работает"
    echo -e "      и с LAN-адреса (патч привилегированного шлюза)"
fi
echo -e "   4. Выберите модель и сохраните"
echo -e "   5. Выберите рабочую папку (Workspace) — иначе композер недоступен"
echo ""
echo -e "💡 Если ключ уже есть в переменной окружения, можно переустановить сервис:"
echo -e "   ${YELLOW}DEEPSEEK_API_KEY=sk-... sudo -E ./dsh_fix.sh${NC}"
echo ""
echo -e "📋 Управление:"
echo -e "   ${YELLOW}sudo systemctl status dsh${NC}"
echo -e "   ${YELLOW}sudo systemctl restart dsh${NC}"
echo -e "   ${YELLOW}sudo journalctl -u dsh -f${NC}"
echo ""
echo -e "🚨  Если Settings → Models ВСЁ ЕЩЁ показывает ошибку:"
echo -e "   1. Сделайте ЖЁСТКОЕ обновление браузера (Ctrl+Shift+R) — JS кэшируется"
echo -e "   2. Проверьте, что оба патча применены:"
echo -e "      ${YELLOW}grep -n 'isTrustedApiRequest(request' \$(find /usr/lib/node_modules -path '*dsh-client-connection/lib/index.js' 2>/dev/null | head -1)${NC}"
echo -e "      ${YELLOW}grep -n 'isLoopback:' \$(find /usr/lib/node_modules -path '*dsh-client-connection/lib/client.js' 2>/dev/null | head -1)${NC}"
echo -e "      Должны быть: 'trustedHosts' в первой и 'isLoopback: true,' во второй"
echo -e "   3. Убедитесь, что dsh запущен именно от того пользователя, для которого"
echo -e "      применены патчи (sudo -E ./dsh_fix.sh от обычного пользователя)"
echo -e "   4. Откройте страницу именно по http://$LAN_IP:${DSH_PORT} (не по hostname)"
echo ""
echo -e "📝 Полный лог: $LOG_FILE"
echo -e "${GREEN}=========================================${NC}"

exit 0
