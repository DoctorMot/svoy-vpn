#!/bin/bash
# «Свой VPN» — серверная часть установщика.
# Ставит Xray (VLESS + REALITY), помощник vpn, защиту сервера и проверяет себя.
# Запускается на сервере от root. Обычно его запускает install.ps1 с компьютера,
# но можно и вручную: bash setup.sh
#
# Повторный запуск безопасен: ключи и выданные устройствам доступы сохраняются.
# Новые ключи — только по явной просьбе: RESET=1 bash setup.sh
#
# Весь человекочитаемый вывод идёт в stderr. В stdout — только служебные блоки
# ===VPN-...===, из которых install.ps1 забирает профиль для компьютера.
set -Eeuo pipefail

# ---------- настройки (можно переопределить переменными окружения) ----------
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"   # проверенная версия: 26.9+ не пускает клиентов mihomo
# официальный установщик XTLS/Xray-install — закреплён на проверенном коммите и сверяется по SHA-256
XRAY_INSTALL_COMMIT="${XRAY_INSTALL_COMMIT:-e741a4f56d368afbb9e5be3361b40c4552d3710d}"
XRAY_INSTALL_SHA256="${XRAY_INSTALL_SHA256:-7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555}"
CFG="${VPN_CONFIG:-/usr/local/etc/xray/config.json}"
OUT="${VPN_OUT:-/root/vpn-keys}"
LOGDIR="${VPN_LOGDIR:-/var/log/xray}"
PC_KEY="${PC_KEY:-clash}"                  # имя ключа для компьютера
NEW_PORTS="${PORTS:-443}"                  # порты для новой установки (через пробел)
SELFTEST_URL="${SELFTEST_URL:-https://www.gstatic.com/generate_204}"
RESET="${RESET:-}"
SKIP_APT="${SKIP_APT:-}"                   # для тестов
SKIP_XRAY_INSTALL="${SKIP_XRAY_INSTALL:-}" # для тестов
DEST_CANDIDATES="${VPN_DEST_CANDIDATES:-www.bing.com dl.google.com www.microsoft.com www.samsung.com www.asus.com www.amd.com www.dell.com www.nvidia.com www.logitech.com www.hp.com}"
# Сайты-прикрытия, которые нельзя брать: заблокированы или замедляются в России,
# либо сам Xray предупреждает, что с ними IP блокируют чаще.
BAD_DEST_RE='(^|\.)(speedtest\.net|ooklaserver\.net|cloudflare\.com|one\.one\.one\.one|apple\.com|icloud\.com)$'

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

# две установки одновременно (например, повтор после обрыва связи) — вторая ждёт первую
if command -v flock >/dev/null 2>&1; then
  exec 9>/run/vpn-setup.lock
  if ! flock -n 9; then
    printf '    Предыдущая установка ещё идёт — жду её окончания…\n' >&2
    flock -w 900 9 || die "Предыдущая установка не закончилась за 15 минут. Перезагрузи сервер (reboot) и запусти снова."
  fi
fi

bad_dest(){ [[ "$1" =~ $BAD_DEST_RE ]]; }

probe_dest() {  # TLS 1.3 + HTTP/2 + сертификат ECDSA
  local d="$1" alg alpn
  alg=$(timeout 12 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 </dev/null 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null | grep -m1 "Public Key Algorithm" | sed 's/.*: //' || true)
  alpn=$(timeout 12 openssl s_client -connect "$d:443" -servername "$d" -alpn h2 -tls1_3 </dev/null 2>/dev/null \
        | grep -c "ALPN protocol: h2" || true)
  [ -n "$alg" ] || { echo "нет TLS 1.3 или сайт недоступен"; return 1; }
  [ "$alg" = "id-ecPublicKey" ] || { echo "сертификат не ECDSA"; return 1; }
  [ "$alpn" = "1" ] || { echo "нет HTTP/2"; return 1; }
  echo "подходит"
}

# ============================================================================
step 1/8 "Проверка сервера"
[ "$(id -u)" = 0 ] || die "Нужны права root: зайди как root или выполни через sudo."
[ -r /etc/os-release ] && . /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "${PRETTY_NAME:-$ID}" ;;
  *) die "Поддерживаются Ubuntu 22.04/24.04 и Debian 12. Здесь: ${PRETTY_NAME:-неизвестная система}" ;;
esac
command -v systemctl >/dev/null || die "Нет systemd — такой сервер не подходит."
if systemctl list-unit-files 2>/dev/null | grep -qE '^(x-ui|3x-ui)\.service'; then
  die "На сервере стоит панель 3x-ui. Ставить поверх нельзя — переустанови ОС в панели хостера и запусти снова."
fi
# порты SSH: тот, через который мы зашли, плюс все из настроек sshd — firewall не отрежет вход
SSH_PORTS=""
if [ -n "${SSH_CONNECTION:-}" ]; then SSH_PORTS=$(awk '{print $4}' <<<"$SSH_CONNECTION"); fi
SSH_PORTS="$SSH_PORTS $( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}')"
SSH_PORTS=$(tr ' ' '\n' <<<"$SSH_PORTS" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ $//' || true)
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
ok "SSH на порту(ах) $SSH_PORTS"

# ============================================================================
step 2/8 "Пакеты"
if [ -n "$SKIP_APT" ]; then
  warn "пропускаю (SKIP_APT)"
else
  say "обновляю список пакетов (на новом сервере может занять пару минут)…"
  # на свежем сервере apt часто занят автообновлением — ждём до 5 минут
  for i in $(seq 30); do
    if upd=$("${APT[@]}" update 2>&1); then break; fi
    # занят автообновлением — ждём; другая ошибка (например, сломанный сторонний репозиторий) —
    # после трёх попыток пробуем ставить со старыми списками
    if ! grep -qi 'lock' <<<"$upd" && [ "$i" -ge 3 ]; then
      warn "список пакетов обновился с ошибкой — пробую ставить со старым:"
      { grep -E '^(E|W):' <<<"$upd" | tail -3 | sed 's/^/      /' >&2; } || true
      break
    fi
    [ "$i" = 30 ] && die "apt занят или недоступен уже 5 минут. Подожди и запусти установку снова."
    sleep 10
  done
  ilog=$(mktemp)
  if ! "${APT[@]}" -y install curl ca-certificates openssl python3 unzip qrencode logrotate \
      ufw fail2ban python3-systemd unattended-upgrades nftables >"$ilog" 2>&1; then
    { grep -E '^(E|W):' "$ilog" | tail -5 >&2; } || true
    die "Не удалось поставить пакеты (ошибки apt выше)."
  fi
  rm -f "$ilog"
  ok "curl, openssl, python3, qrencode, ufw, fail2ban, unattended-upgrades"
fi

# ============================================================================
step 3/8 "Xray"
cur=$(xray version 2>/dev/null | awk 'NR==1{print $2}' || true)
if [ -n "$SKIP_XRAY_INSTALL" ]; then
  warn "пропускаю установку (SKIP_XRAY_INSTALL), найдена версия: ${cur:-нет}"
elif [ "$cur" = "${XRAY_VERSION#v}" ]; then
  ok "Xray $cur уже стоит"
else
  say "ставлю Xray $XRAY_VERSION официальным скриптом XTLS…"
  inst=$(mktemp); ilog=$(mktemp)
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/XTLS/Xray-install/$XRAY_INSTALL_COMMIT/install-release.sh" -o "$inst" \
    || die "Не удалось скачать установщик Xray с GitHub. Проверь, открывается ли github.com с сервера."
  echo "$XRAY_INSTALL_SHA256  $inst" | sha256sum -c --quiet >/dev/null 2>&1 \
    || die "Установщик Xray не совпал с проверенной копией (SHA-256). Остановился, ничего не поставив."
  # скрипт сам сверяет SHA-256 архива Xray; базы geoip/geosite не нужны — конфиг их не использует
  if ! bash "$inst" install --version "$XRAY_VERSION" --without-geodata >"$ilog" 2>&1; then
    { tail -5 "$ilog" >&2; } || true
    die "Не удалось поставить Xray. Проверь, открывается ли github.com с сервера."
  fi
  rm -f "$inst" "$ilog"
  cur=$(xray version 2>/dev/null | awk 'NR==1{print $2}')
  ok "Xray $cur"
fi
command -v xray >/dev/null || die "Xray не найден."

# ============================================================================
step 4/8 "Ключи"
mkdir -p "$OUT" "$(dirname "$CFG")"; chmod 700 "$OUT"
MODE=new
if [ -z "$RESET" ] && [ -s "$CFG" ] && python3 - "$CFG" <<'PY' 2>/dev/null
import json, sys
c = json.load(open(sys.argv[1]))
v = [i for i in c.get("inbounds", []) if i.get("protocol") == "vless"
     and i.get("streamSettings", {}).get("security") == "reality"]
sys.exit(0 if v else 1)
PY
then MODE=upgrade; fi

if [ "$MODE" = upgrade ]; then
  mapfile -t E < <(python3 - "$CFG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
v = [i for i in c["inbounds"] if i.get("protocol") == "vless"
     and i.get("streamSettings", {}).get("security") == "reality"]
r = v[0]["streamSettings"]["realitySettings"]
print(r["privateKey"])
print(json.dumps(r.get("shortIds") or []))
print((r.get("serverNames") or [""])[0])
print(json.dumps(r.get("serverNames") or []))
print(" ".join(str(i["port"]) for i in v))
PY
)
  PRIV="${E[0]}"; SIDS_JSON="${E[1]}"; OLD_DEST="${E[2]}"; OLD_NAMES_JSON="${E[3]}"; PORTS_USE="${E[4]}"
  [ "$SIDS_JSON" != "[]" ] || SIDS_JSON="[\"$(openssl rand -hex 8)\"]"
  ok "VPN уже установлен — сохраняю ключи и выданные доступы (новые ключи: RESET=1)"
else
  kp=$(xray x25519)
  PRIV=$(awk -F': *' '/^Private/{print $2; exit}' <<<"$kp")
  SIDS_JSON="[\"$(openssl rand -hex 8)\"]"
  OLD_DEST=""; OLD_NAMES_JSON="[]"; PORTS_USE="$NEW_PORTS"
  ok "созданы новые ключи шифрования"
fi
PUB=$(xray x25519 -i "$PRIV" | awk -F': *' '/^(Password|Public)/ && !f {print $2; f=1}')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "Не удалось получить ключи REALITY (xray x25519)."

# ============================================================================
step 5/8 "Сайт-прикрытие"
DEST=""
if [ -n "${DEST_OVERRIDE:-}" ]; then
  r=$(probe_dest "$DEST_OVERRIDE") || die "$DEST_OVERRIDE не подходит: $r"
  DEST="$DEST_OVERRIDE"; ok "$DEST (задан вручную)"
elif [ -n "$OLD_DEST" ] && ! bad_dest "$OLD_DEST"; then
  # у выданных устройствам ссылок это имя вшито — без веской причины не меняем
  DEST="$OLD_DEST"
  if r=$(probe_dest "$OLD_DEST"); then ok "оставляю прежний: $DEST"
  else warn "оставляю прежний $DEST, хотя проверка не прошла ($r). Если связь плохая — vpn dest auto"; fi
else
  [ -n "$OLD_DEST" ] && warn "прежний $OLD_DEST заблокирован или замедляется в России — меняю"
  for d in $DEST_CANDIDATES; do
    bad_dest "$d" && continue
    if r=$(probe_dest "$d"); then DEST="$d"; ok "$d — $r"; break; else say "$d — $r"; fi
  done
  [ -n "$DEST" ] || die "Ни один сайт-прикрытие не подошёл. Задай вручную: DEST_OVERRIDE=сайт bash setup.sh"
fi
DEST_CHANGED=""
[ "$MODE" = upgrade ] && [ "$DEST" != "$OLD_DEST" ] && DEST_CHANGED=1

# ============================================================================
step 6/8 "Настройка Xray"
[ -f "$CFG" ] && cp "$CFG" "$OUT/config-before-setup-$(date +%Y%m%d-%H%M%S).json"
mkdir -p "$LOGDIR"
NEW_UUID=$(xray uuid)
python3 - "$CFG" "$MODE" "$PRIV" "$SIDS_JSON" "$DEST" "$PORTS_USE" "$PC_KEY" "$NEW_UUID" "$LOGDIR" "$OLD_DEST" "$OLD_NAMES_JSON" <<'PY'
import json, sys, os
cfg, mode, priv, sids_json, dest, ports, pc_key, new_uuid, logdir, old_dest, old_names_json = sys.argv[1:12]
sids = json.loads(sids_json)
names = json.loads(old_names_json) if dest == old_dest and old_names_json != "[]" else [dest]
if dest not in names: names.insert(0, dest)
clients, seen = [], set()
if mode == "upgrade":
    old = json.load(open(cfg))
    other = []
    for i in old.get("inbounds", []):
        if i.get("protocol") != "vless" or i.get("streamSettings", {}).get("security") != "reality":
            other.append(f'{i.get("protocol", "?")}:{i.get("port", "?")}')
            continue
        for u in i.get("settings", {}).get("clients", []):
            key = u.get("email") or u.get("id")
            if key in seen: continue
            seen.add(key)
            clients.append({"id": u["id"], "flow": "xtls-rprx-vision", "email": u.get("email") or u["id"][:8]})
    if other:
        print(f"    ! в старом конфиге были другие входы ({', '.join(other)}) — они не переносятся, копия конфига лежит в папке ключей", file=sys.stderr)
if not any(c["email"] == pc_key for c in clients):
    clients.insert(0, {"id": new_uuid, "flow": "xtls-rprx-vision", "email": pc_key})

def inbound(port):
    return {
        "tag": "vless-reality" if port == 443 else f"vless-reality-{port}",
        "listen": "0.0.0.0", "port": port, "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none"},
        "streamSettings": {"network": "tcp", "security": "reality",
            "realitySettings": {"show": False, "dest": f"{dest}:443", "xver": 0,
                "serverNames": names, "privateKey": priv, "shortIds": sids}},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
    }

private = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
           "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"]
c = {
    "log": {"loglevel": "warning", "access": f"{logdir}/access.log", "error": f"{logdir}/error.log"},
    # DNS-запросы устройств сервер обрабатывает сам (vpn dns on/off)
    "dns": {"servers": ["localhost", "https+local://1.1.1.1/dns-query"], "queryStrategy": "UseIPv4"},
    "inbounds": [inbound(int(p)) for p in ports.split()],
    "outbounds": [{"tag": "direct", "protocol": "freedom"},
                  {"tag": "block", "protocol": "blackhole"},
                  {"tag": "dns-out", "protocol": "dns"}],
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
        {"type": "field", "port": "53", "outboundTag": "dns-out"},
        # сервер не пускает в свою локальную сеть
        {"type": "field", "ip": private, "outboundTag": "block"},
        # торренты через VPN — прямой путь к жалобам правообладателей хостеру
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    ]},
}
tmp = cfg + ".new.json"   # Xray определяет формат по расширению
json.dump(c, open(tmp, "w"), indent=2)
os.chmod(tmp, 0o644)
PY
if ! xray run -test -config "$CFG.new.json" >/dev/null 2>&1; then
  { xray run -test -config "$CFG.new.json" 2>&1 | tail -5 >&2; } || true
  rm -f "$CFG.new.json"; die "Новый конфиг не прошёл проверку Xray — прежний оставлен без изменений."
fi
mv "$CFG.new.json" "$CFG"
chown -R nobody:nogroup "$LOGDIR" 2>/dev/null || true
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray; sleep 2
systemctl is-active --quiet xray || die "Xray не запустился. Журнал: journalctl -u xray -n 30"
ok "VLESS + REALITY на порту(ах) $PORTS_USE, прикрытие $DEST"

# сеть: BBR и ротация журналов
cat > /etc/sysctl.d/99-vpn-setup.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=8192
EOF
sysctl --system >/dev/null 2>&1 || true
cat > /etc/logrotate.d/xray <<EOF
$LOGDIR/*.log {
    daily
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF
ok "BBR включён, журналы хранятся 3 дня"

# ============================================================================
step 7/8 "Защита сервера"
if command -v ufw >/dev/null; then
  for p in $SSH_PORTS $PORTS_USE; do ufw allow "$p"/tcp >/dev/null; done
  ufw --force enable >/dev/null
  ok "firewall включён: разрешены SSH ($SSH_PORTS) и VPN ($PORTS_USE)"
else
  warn "ufw не найден — firewall не настроен"
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
  if systemctl is-active --quiet fail2ban; then ok "fail2ban: 5 неверных паролей — бан SSH на 10 минут (VPN не трогает)"
  else warn "fail2ban не запустился — проверь: systemctl status fail2ban"; fi
else
  warn "fail2ban не найден — защита от подбора пароля не настроена"
fi
if [ -z "$SKIP_APT" ]; then
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "автоматические обновления безопасности включены"
fi
say "Пароль root установщик не меняет. Смени его сам: команда passwd."

# ============================================================================
step 8/8 "Самопроверка"
command -v vpn >/dev/null || die "Помощник vpn не найден в /usr/local/bin — установка неполная."
set -- $PORTS_USE
ST=$(mktemp /tmp/vpn-selftest-XXXXXX.json)
python3 - "$CFG" "$PC_KEY" "$PUB" "$1" > "$ST" <<'PY'
import json, sys
cfg, name, pub, port = sys.argv[1:5]
c = json.load(open(cfg))
i = [x for x in c["inbounds"] if x.get("protocol") == "vless"][0]
u = [x for x in i["settings"]["clients"] if x.get("email") == name][0]
r = i["streamSettings"]["realitySettings"]
print(json.dumps({
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 10899, "protocol": "socks", "settings": {"udp": True}}],
  "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": int(port),
      "users": [{"id": u["id"], "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
      "serverName": r["serverNames"][0], "fingerprint": "chrome", "publicKey": pub, "shortId": next((s for s in r["shortIds"] if s), "")}}}]}))
PY
xray run -config "$ST" >/dev/null 2>&1 &
TPID=$!
sleep 2
code=""
for try in 1 2 3; do   # первое соединение после перезапуска Xray бывает медленным
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --noproxy '' --socks5-hostname 127.0.0.1:10899 "$SELFTEST_URL" || true)
  case "$code" in 2*|3*) break ;; esac
  sleep 2
done
kill "$TPID" 2>/dev/null || true; wait "$TPID" 2>/dev/null || true
rm -f "$ST"
case "$code" in
  2*|3*) ok "запрос через VPN прошёл (ответ $code)" ;;
  *) die "Самопроверка не прошла (ответ ${code:-нет}). Настройки оставлены для разбора: vpn status, journalctl -u xray -n 30" ;;
esac

vpn yaml "$PC_KEY" >/dev/null
[ -s "$OUT/$PC_KEY.yaml" ] || die "Не удалось собрать профиль для компьютера."

IP=$(vpn status 2>/dev/null | awk -F': *' '/^IP сервера/ && !f {print $2; f=1}' || true)
printf "\n${C2}Готово.${C0} Сервер %s, прикрытие %s, порт(ы) %s.\n" "$IP" "$DEST" "$PORTS_USE" >&2
vpn list >&2 || true
if [ -n "$DEST_CHANGED" ]; then
  warn "Сайт-прикрытие сменился ($OLD_DEST → $DEST). Старые ссылки и профили больше не подключатся:"
  warn "компьютер получит новый профиль сейчас, телефоны обнови: vpn link ИМЯ (QR) или vpn yaml ИМЯ (FlClash)."
fi

# ---- служебный вывод для install.ps1 ----
echo "===VPN-INFO ip=$IP ports=${PORTS_USE// /,} dest=$DEST mode=$MODE dest_changed=${DEST_CHANGED:-0}==="
echo "===VPN-FILE vpn-$PC_KEY.yaml==="
base64 -w 76 "$OUT/$PC_KEY.yaml"
echo "===VPN-END==="
