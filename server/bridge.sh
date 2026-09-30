#!/bin/bash
# «Свой VPN» — мост через российский сервер: прозрачный проброс на зарубежный VPN-сервер.
#
#   устройство → ЭТОТ СЕРВЕР:443 → ЗАРУБЕЖНЫЙ СЕРВЕР:443 → интернет
#
# Пересылку делает ядро (правило nftables). Шифрование идёт от устройства сразу до зарубежного
# сервера: на мосту нет ни ключей, ни Xray, ни журнала соединений — прочитать трафик он не может.
# Что мост всё-таки видит (IP устройства, время, объём, адрес зарубежного сервера, имя
# сайта-прикрытия) — в гайде, глава «Мост через российский сервер».
#
# Запускается на мосту от root. Обычно его запускает install.ps1 (режим «мост»), но можно и вручную:
#   UPSTREAM=203.0.113.10 bash bridge.sh
# Повторный запуск безопасен. С другим UPSTREAM — переключает мост на другой сервер.
#
# Весь человекочитаемый вывод идёт в stderr, в stdout — только служебная строка ===VPN-INFO …===.
set -Eeuo pipefail

VERSION=1.1.0                               # сверяется с файлом VERSION при сборке (tools/build.py)
UPSTREAM="${UPSTREAM:-}"                    # IP зарубежного сервера
BRIDGE_PORTS="${BRIDGE_PORTS:-443}"         # «443» или «443:8443» (порт моста:порт сервера), через пробел
DIR="${BRIDGE_DIR:-/etc/svoy-vpn}"          # настройки моста
UNIT_DIR="${BRIDGE_UNIT_DIR:-/etc/systemd/system}"
SKIP_APT="${SKIP_APT:-}"                    # для тестов
TABLE=svoy_bridge                           # своя таблица nftables: чужие правила (ufw) не трогаем

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT=(apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -qq)

# ---------- вывод ----------
if [ -n "${NO_COLOR:-}" ]; then C1=; C2=; C3=; C4=; C0=; else C1='\033[1;36m'; C2='\033[32m'; C3='\033[33m'; C4='\033[31m'; C0='\033[0m'; fi
step(){ printf "\n${C1}[%s]${C0} %s\n" "$1" "$2" >&2; }
say(){  printf '    %s\n' "$*" >&2; }
ok(){   printf "    ${C2}✓${C0} %s\n" "$*" >&2; }
warn(){ printf "    ${C3}!${C0} %s\n" "$*" >&2; }
die(){  printf "\n${C4}✗ %s${C0}\n" "$*" >&2; exit 1; }
trap 'die "Сбой в строке $LINENO: $BASH_COMMAND"' ERR
trap '' HUP   # обрыв SSH не должен прерывать установку на середине

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/vpn-setup.lock
  if ! flock -n 9; then
    printf '    Предыдущая установка ещё идёт — жду её окончания…\n' >&2
    flock -w 900 9 || die "Предыдущая установка не закончилась за 15 минут. Перезагрузи сервер (reboot) и запусти снова."
  fi
fi

# ---------- apt на новом сервере (как в setup.sh) ----------
apt_locked() {  # 0 — apt/dpkg сейчас занят другим процессом
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY_LOCK'
import fcntl, os, sys
for p in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
          "/var/lib/apt/lists/lock", "/var/cache/apt/archives/lock"):
    try:
        fd = os.open(p, os.O_RDWR)
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)
    finally:
        os.close(fd)
sys.exit(1)
PY_LOCK
  else
    pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -f '/unattended-upgrade( |$)' >/dev/null 2>&1
  fi
}
cloud_init_running() {
  command -v cloud-init >/dev/null 2>&1 && cloud-init status 2>/dev/null | grep -q 'status: running'
}
wait_apt() {
  local t=0 said=""
  while apt_locked || { [ "$t" -lt 900 ] && cloud_init_running; }; do
    if [ -z "$said" ]; then
      say "сервер сам ставит обновления системы — на только что созданном сервере это нормально,"
      say "обычно 5–20 минут. Жду, пока закончит. Окно не закрывай."
      said=1
    fi
    sleep 15; t=$((t + 15))
    if [ $((t % 60)) -eq 0 ]; then say "…обновления системы ещё идут, жду уже $((t / 60)) мин"; fi
    [ "$t" -lt 2700 ] || die "Обновления системы идут дольше 45 минут. Перезагрузи сервер в панели хостера (reboot) и запусти установку снова."
  done
  if [ -n "$said" ]; then ok "система закончила обновляться"; fi
  dpkg --configure -a --force-confdef --force-confold >/dev/null 2>&1 || true
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# ============================================================================
step 1/5 "Проверка сервера"
[ "$(id -u)" = 0 ] || die "Нужны права root: зайди как root или выполни через sudo."
[ -r /etc/os-release ] && . /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "${PRETTY_NAME:-$ID}" ;;
  *) die "Поддерживаются Ubuntu 22.04/24.04 и Debian 12. Здесь: ${PRETTY_NAME:-неизвестная система}" ;;
esac
command -v systemctl >/dev/null || die "Нет systemd — такой сервер не подходит."

[ -n "$UPSTREAM" ] || die "Не задан адрес зарубежного сервера. Запуск: UPSTREAM=IP_СЕРВЕРА bash bridge.sh"
is_ipv4 "$UPSTREAM" || die "«$UPSTREAM» — не IPv4-адрес. Нужен IP зарубежного сервера вида 203.0.113.10"
case "$UPSTREAM" in
  0.*|127.*|10.*|192.168.*|169.254.*) die "$UPSTREAM — внутренний адрес. Нужен внешний IP зарубежного сервера." ;;
esac
MY_IPS=" $(hostname -I 2>/dev/null || true) "
[[ "$MY_IPS" != *" $UPSTREAM "* ]] || die "$UPSTREAM — это адрес самого моста. Нужен IP зарубежного сервера."

# порты SSH: тот, через который мы зашли, плюс все из настроек sshd — их пробрасывать нельзя
SSH_PORTS=""
if [ -n "${SSH_CONNECTION:-}" ]; then SSH_PORTS=$(awk '{print $4}' <<<"$SSH_CONNECTION"); fi
SSH_PORTS="$SSH_PORTS $( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}')"
SSH_PORTS=$(tr ' ' '\n' <<<"$SSH_PORTS" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ $//' || true)
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
ok "SSH на порту(ах) $SSH_PORTS"

# пары «порт моста → порт сервера»
MAP=()
for m in $BRIDGE_PORTS; do
  bp="${m%%:*}"; up="${m#*:}"
  is_port "$bp" && is_port "$up" || die "BRIDGE_PORTS: «$m» — нужен порт (443) или пара портов (443:8443)."
  [[ " $SSH_PORTS " != *" $bp "* ]] || die "Порт $bp занят SSH — если пробросить его, на мост будет не зайти."
  MAP+=("$bp:$up")
done
[ ${#MAP[@]} -gt 0 ] || die "BRIDGE_PORTS пуст."

# VPN-программы на мосту не нужны: ключей здесь быть не должно, а хостер видит процессы
if systemctl list-unit-files 2>/dev/null | grep -qE '^(x-ui|3x-ui)\.service'; then
  warn "на этом сервере стоит панель 3x-ui. Мосту она не нужна и выдаёт хостеру, что здесь VPN."
  warn "Лучше переустановить ОС в панели хостера и запустить установку моста снова."
elif command -v xray >/dev/null 2>&1 || [ -e /usr/local/etc/xray/config.json ]; then
  warn "на этом сервере стоит Xray. Мосту он не нужен: правило пересылки работает без него."
  warn "Если это не твой зарубежный VPN-сервер, лучше переустановить ОС и запустить установку моста снова."
fi
for m in "${MAP[@]}"; do
  bp="${m%%:*}"
  if (ss -tln 2>/dev/null || true) | awk '{print $4}' | grep -qE "[:.]$bp\$"; then
    warn "на порту $bp здесь уже что-то работает — снаружи оно станет недоступно: порт займёт мост."
  fi
done

OLD_UPSTREAM=""; OLD_PORTS=""; PREV_VERSION=""
if [ -s "$DIR/bridge.conf" ]; then
  OLD_UPSTREAM=$(sed -n 's/^UPSTREAM=//p' "$DIR/bridge.conf" | head -1)
  OLD_PORTS=$(sed -n 's/^BRIDGE_PORTS=//p' "$DIR/bridge.conf" | head -1)
  PREV_VERSION=$(sed -n 's/^VERSION=//p' "$DIR/bridge.conf" | head -1)
fi
MODE=new; [ -n "$OLD_UPSTREAM" ] && MODE=upgrade
if [ "$MODE" = upgrade ]; then
  if [ "$OLD_UPSTREAM" != "$UPSTREAM" ]; then ok "мост уже настроен (на $OLD_UPSTREAM) — переключаю на $UPSTREAM"
  else ok "мост уже настроен — обновляю (версия ${PREV_VERSION:-1.1.0} → $VERSION)"; fi
fi

# ============================================================================
step 2/5 "Пакеты"
if [ -n "$SKIP_APT" ]; then
  warn "пропускаю (SKIP_APT)"
else
  wait_apt
  say "обновляю список пакетов…"
  for i in $(seq 30); do
    if upd=$("${APT[@]}" update 2>&1); then break; fi
    wait_apt
    if ! grep -qi 'lock' <<<"$upd" && [ "$i" -ge 3 ]; then
      warn "список пакетов обновился с ошибкой — пробую ставить со старым:"
      { grep -E '^(E|W):' <<<"$upd" | tail -3 | sed 's/^/      /' >&2; } || true
      break
    fi
    [ "$i" = 30 ] && die "apt занят или недоступен уже 5 минут. Подожди и запусти установку снова."
    sleep 10
  done
  wait_apt
  say "ставлю пакеты (1–2 минуты)…"
  ilog=$(mktemp)
  if ! "${APT[@]}" -y install nftables ufw fail2ban python3-systemd unattended-upgrades >"$ilog" 2>&1; then
    { grep -E '^(E|W):' "$ilog" | tail -5 >&2; } || true
    die "Не удалось поставить пакеты (ошибки apt выше)."
  fi
  rm -f "$ilog"
  ok "nftables, ufw, fail2ban, unattended-upgrades"
fi
NFT=$(command -v nft || true)
[ -n "$NFT" ] || die "Нет nft (пакет nftables)."

# ============================================================================
step 3/5 "Проброс на $UPSTREAM"
mkdir -p "$DIR"; chmod 755 "$DIR"
{
  echo "# Свой VPN — мост. Файл пишет bridge.sh; руками не править — повторный запуск его перезапишет."
  echo "# Первые две строки удаляют прежнюю таблицу моста: правила заменяются целиком и атомарно."
  echo "table inet $TABLE"
  echo "delete table inet $TABLE"
  echo "table inet $TABLE {"
  echo "  chain prerouting {"
  echo "    type nat hook prerouting priority dstnat; policy accept;"
  for m in "${MAP[@]}"; do
    echo "    meta nfproto ipv4 fib daddr type local tcp dport ${m%%:*} dnat ip to $UPSTREAM:${m#*:}"
  done
  echo "  }"
  echo "  chain postrouting {"
  echo "    type nat hook postrouting priority srcnat; policy accept;"
  for m in "${MAP[@]}"; do
    echo "    ct status dnat ip daddr $UPSTREAM tcp dport ${m#*:} masquerade"
  done
  echo "  }"
  echo "}"
} > "$DIR/bridge.nft.new"
"$NFT" -c -f "$DIR/bridge.nft.new" || { rm -f "$DIR/bridge.nft.new"; die "Правила nftables не прошли проверку — прежние оставлены."; }
mv "$DIR/bridge.nft.new" "$DIR/bridge.nft"

# пересылка пакетов между сетями — без неё ядро выбрасывает всё, что не адресовано самому мосту
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-svoy-bridge.conf
sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# свой юнит, а не nftables.service: тот при старте делает «flush ruleset» и снёс бы правила ufw
cat > "$UNIT_DIR/svoy-bridge.service" <<EOF
[Unit]
Description=Svoy VPN bridge: TCP forwarding to $UPSTREAM (nftables table inet $TABLE)
After=network-pre.target nftables.service ufw.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f $DIR/bridge.nft
ExecStop=$NFT delete table inet $TABLE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable svoy-bridge >/dev/null 2>&1 || true
systemctl restart svoy-bridge
"$NFT" list table inet "$TABLE" >/dev/null 2>&1 || die "Правило пересылки не загрузилось. Журнал: journalctl -u svoy-bridge -n 20"
for m in "${MAP[@]}"; do ok "порт ${m%%:*} моста → $UPSTREAM:${m#*:} (правило переживает перезагрузку)"; done

{
  echo "# Свой VPN — мост. Пишет bridge.sh."
  echo "VERSION=$VERSION"
  echo "UPSTREAM=$UPSTREAM"
  echo "BRIDGE_PORTS=${MAP[*]}"
} > "$DIR/bridge.conf"

# ============================================================================
step 4/5 "Защита сервера"
if command -v ufw >/dev/null; then
  for p in $SSH_PORTS; do ufw allow "$p"/tcp >/dev/null; done
  # прежние разрешения пересылки (другой сервер или порты) — убираем
  for m in $OLD_PORTS; do
    [[ " ${MAP[*]} " == *" $m "* ]] && [ "$OLD_UPSTREAM" = "$UPSTREAM" ] && continue
    ufw route delete allow proto tcp to "$OLD_UPSTREAM" port "${m#*:}" >/dev/null 2>&1 || true
  done
  # после DNAT пакет идёт через цепочку FORWARD, а там у ufw по умолчанию запрет.
  # Разрешаем ровно одно: пересылку к зарубежному серверу на его порт VPN.
  for m in "${MAP[@]}"; do
    ufw route allow proto tcp to "$UPSTREAM" port "${m#*:}" comment 'svoy-vpn bridge' >/dev/null
  done
  ufw logging off >/dev/null            # не записывать адреса подключений в журнал ядра
  ufw --force enable >/dev/null
  ok "firewall включён: SSH ($SSH_PORTS) и пересылка к $UPSTREAM; журнал firewall выключен"
else
  die "ufw не найден — без него пересылку не настроить безопасно."
fi
if [ -d /etc/fail2ban ]; then
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/vpn-setup.local <<EOF
[sshd]
enabled  = true
backend  = systemd
port     = ${SSH_PORTS// /,}
maxretry = 5
findtime = 10m
bantime  = 10m
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
  if systemctl is-active --quiet fail2ban; then ok "fail2ban: 5 неверных паролей — бан SSH на 10 минут (пересылку не трогает)"
  else warn "fail2ban не запустился — проверь: systemctl status fail2ban"; fi
else
  warn "fail2ban не найден — защита от подбора пароля не настроена"
fi
if [ -z "$SKIP_APT" ]; then
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "автоматические обновления безопасности включены"
fi
# журнал системы — только в памяти: после перезагрузки на диске не остаётся, кто и когда заходил
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/svoy-bridge.conf <<'EOF'
# Свой VPN — мост: журнал только в памяти (до 32 МБ), на диск и в syslog не пишется
[Journal]
Storage=volatile
RuntimeMaxUse=32M
ForwardToSyslog=no
EOF
systemctl restart systemd-journald >/dev/null 2>&1 || true
if [ -d /var/log/journal ]; then find /var/log/journal -mindepth 1 -delete 2>/dev/null || true; fi
ok "журнал системы хранится только в памяти и стирается при перезагрузке"
say "Пароль root установщик не меняет. Смени его сам: команда passwd."

# ============================================================================
step 5/5 "Самопроверка"
[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ] || die "Пересылка пакетов (ip_forward) не включилась."
ok "пересылка пакетов включена"
REACH=1
for m in "${MAP[@]}"; do
  up="${m#*:}"
  if timeout 8 bash -c "exec 3<>/dev/tcp/$UPSTREAM/$up" 2>/dev/null; then
    ok "зарубежный сервер $UPSTREAM:$up отвечает с моста"
  else
    REACH=0
    warn "зарубежный сервер $UPSTREAM:$up с моста НЕ отвечает."
    warn "Если VPN на нём ещё не установлен — это нормально. Иначе проверь IP и что сервер включён."
  fi
done
say "Сквозная проверка — с зарубежного сервера (ключи есть только у него): vpn bridge test IP_МОСТА"

MY_IP=$(tr ' ' '\n' <<<"$MY_IPS" | grep -Ev '^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|169\.254\.)' | grep -E '^[0-9.]+$' | head -1 || true)
printf "\n${C2}Готово.${C0} Мост ${MY_IP:-(IP не определён)} → %s, порт(ы) %s.\n" "$UPSTREAM" "${MAP[*]}" >&2

# ---- служебный вывод для install.ps1 ----
p=""; for m in "${MAP[@]}"; do p+="${m%%:*},"; done
echo "===VPN-INFO role=bridge ip=${MY_IP:-} upstream=$UPSTREAM ports=${p%,} mode=$MODE prev=${OLD_UPSTREAM:-} reach=$REACH version=$VERSION==="
