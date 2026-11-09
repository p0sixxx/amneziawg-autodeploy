#!/usr/bin/env bash
# amneziawg-autodeploy — обёртка над install_amneziawg.sh (форк bivlked/amneziawg-installer v6.2.1).
#
# Что добавляет поверх установщика:
#   * проверки сервера и сети до установки (ОС, архитектура, виртуализация, RAM, диск,
#     DNS, доступ к GitHub и PPA, публичный IP, NAT, время);
#   * проверку, не заблокирован ли IP сервера в России (check-host.net: узлы в РФ и Европе);
#   * случайный UDP-порт вместо известного всем 39743;
#   * безопасные флаги по умолчанию: не удалять системные пакеты, не отключать IPv6 на хосте,
#     модуль только из официального PPA через DKMS (без готовых .deb из чужих релизов);
#   * загрузку установщика с проверкой SHA256 (pin в этом файле);
#   * автоматическое продолжение после перезагрузок (systemd oneshot);
#   * своих клиентов (CLIENTS=phone,laptop) и итоговую проверку.
#
# Установка (на чистом Ubuntu 24.04 / Debian 13):
#   curl -fsSLo /root/awg-autodeploy.sh https://raw.githubusercontent.com/p0sixxx/amneziawg-autodeploy/main/autodeploy.sh
#   bash /root/awg-autodeploy.sh --dry-run      # только план
#   bash /root/awg-autodeploy.sh                # установка
#
# Команды:  install (по умолчанию) | check | status | resume | help
# Опции:    --dry-run --yes --non-interactive --port=N --mobile --protocol=3.1|2.0
#           --endpoint=АДРЕС --clients=a,b --allow-blocked-ip --skip-external-check
#           -- <любые флаги install_amneziawg.sh>
# shellcheck disable=SC2015  # ok/warn/fail всегда возвращают 0
set -Eeuo pipefail

AD_VERSION="1.0.0"
AD_REPO_RAW="${AD_REPO_RAW:-https://raw.githubusercontent.com/p0sixxx/amneziawg-autodeploy}"
AD_REF="${AD_REF:-main}"
# SHA256 install_amneziawg.sh этого репозитория. Обновляет scripts/update-autodeploy-pin.sh.
INSTALLER_SHA256="b4842d81b455d3155c540f68ec2692f1fd148911a326a027342297753df46395"

AD_DIR=/root/awg-autodeploy
AD_STATE="$AD_DIR/autodeploy.env"
AD_LOG=/var/log/awg-autodeploy.log
AD_BIN=/usr/local/sbin/awg-autodeploy
AD_UNIT=/etc/systemd/system/awg-autodeploy-resume.service
AWG_DIR=/root/awg
CH=https://check-host.net

# ------------------------------------------------------------------ вывод
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; fi
log()  { printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$AD_LOG" 2>/dev/null || true; }
hdr()  { log ""; log "${C_B}==> $*${C_0}"; }
ok()   { log "    ${C_G}[OK]${C_0} $*"; }
warn() { log "    ${C_Y}[!!]${C_0} $*"; WARNS=$((WARNS + 1)); }
fail() { log "    ${C_R}[FAIL]${C_0} $*"; FAILS=$((FAILS + 1)); }
die()  { log ""; log "${C_R}[СТОП]${C_0} $*"; exit 1; }
WARNS=0; FAILS=0
trap 'rc=$?; [[ $rc -ne 0 ]] && log "Ошибка в строке $LINENO (код $rc). Лог: $AD_LOG"' ERR

# ------------------------------------------------------------------ аргументы
CMD=install; DRY_RUN=0; AUTO_YES=0; PORT="${PORT:-}"; MOBILE="${MOBILE:-0}"; PROTOCOL="${PROTOCOL:-3.1}"
ENDPOINT="${ENDPOINT:-}"; CLIENTS="${CLIENTS:-}"; ALLOW_BLOCKED="${ALLOW_BLOCKED:-0}"; SKIP_EXT="${SKIP_EXTERNAL_CHECK:-0}"
EXTRA=()
while (($#)); do
    case "$1" in
        install|check|status|resume|help) CMD=$1 ;;
        --dry-run) DRY_RUN=1 ;;
        -y|--yes|--non-interactive) AUTO_YES=1 ;;
        --port=*) PORT=${1#*=} ;;
        --mobile) MOBILE=1 ;;
        --protocol=*) PROTOCOL=${1#*=} ;;
        --endpoint=*) ENDPOINT=${1#*=} ;;
        --clients=*) CLIENTS=${1#*=} ;;
        --allow-blocked-ip) ALLOW_BLOCKED=1 ;;
        --skip-external-check) SKIP_EXT=1 ;;
        -h|--help) CMD=help ;;
        --) shift; EXTRA=("$@"); break ;;
        *) die "Неизвестный аргумент: $1 (справка: --help)" ;;
    esac
    shift
done

usage() { sed -n '2,25p' "$AD_BIN" 2>/dev/null || sed -n '2,25p' "$0"; }

need_root() { [[ $EUID -eq 0 ]] || die "Запусти от root (sudo -i)."; }

ask() { # ask "вопрос" → 0 = да
    [[ $AUTO_YES -eq 1 ]] && return 0
    [[ -r /dev/tty ]] || return 1
    local a; read -rp "    $1 [y/N] " a </dev/tty || return 1
    [[ "$a" =~ ^([Yy]|[Yy]es|да|Да|д)$ ]]
}

# ------------------------------------------------------------------ check-host.net
ch_get() { curl -fsS --max-time 20 -H 'Accept: application/json' "$CH$1"; }
ch_nodes() { # до 3 узлов из России и до 3 из Европы
    local j; j=$(ch_get /nodes/hosts) || return 1
    jq -r '[.nodes | to_entries[] | select(.value.location[0] == "ru")] | .[:3][] | .key' <<<"$j"
    jq -r '[.nodes | to_entries[] | select(.value.location[0] as $c
            | ["de","nl","fi","fr","pl","se","gb","uk","ch","at","cz","lt","lv","ee"] | index($c))] | .[:3][] | .key' <<<"$j"
}
probe() { # probe <ip> <port...> → «<port> <ок_РФ>/<всего_РФ> <ок_Европа>/<всего_Европа>» или «<port> ?»
    local ip=$1; shift
    local nodes=() q="" n p id res pairs=()
    mapfile -t nodes < <(ch_nodes 2>/dev/null || true)
    ((${#nodes[@]} > 0)) || return 1
    for n in "${nodes[@]}"; do q+="&node=${n}"; done
    for p in "$@"; do
        id=$(ch_get "/check-tcp?host=${ip}:${p}${q}" 2>/dev/null | jq -r '.request_id // empty' 2>/dev/null || true)
        pairs+=("${p}:${id}")
    done
    sleep 4
    for n in "${pairs[@]}"; do
        p=${n%%:*}; id=${n#*:}
        if [[ -z "$id" ]]; then echo "$p ?"; continue; fi
        res=""
        for _ in $(seq 1 12); do
            res=$(ch_get "/check-result/${id}" 2>/dev/null || true)
            [[ -n "$res" ]] && jq -e 'type == "object" and ([.[] | select(. == null)] | length == 0)' >/dev/null 2>&1 <<<"$res" && break
            sleep 2
        done
        [[ -n "$res" ]] || res='{}'
        # «connection refused» тоже значит, что IP достижим (порт просто закрыт)
        jq -r --arg p "$p" '[to_entries[] | {ru: (.key | startswith("ru")),
              ok: ((.value // [])[0] | if type == "object" then (has("time") or ((.error // "") | test("refused"; "i"))) else false end)}] as $a
            | "\($p) \([$a[] | select(.ru and .ok)] | length)/\([$a[] | select(.ru)] | length) \([$a[] | select((.ru | not) and .ok)] | length)/\([$a[] | select(.ru | not)] | length)"' \
            <<<"$res" 2>/dev/null || echo "$p ?"
    done
}

# ------------------------------------------------------------------ сеть сервера
detect_ip() {
    local u ip
    for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me https://check-host.net/ip; do
        ip=$(curl -4 -fs --max-time 5 "$u" | tr -d '[:space:]"') || continue
        [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return; }
    done
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}
ssh_port() {
    local p
    p=$(ss -Hltnp 2>/dev/null | awk '/"sshd"/ {sub(/.*:/, "", $4); print $4; exit}')
    echo "${p:-22}"
}
udp_busy() { [[ -n "$(ss -Hlun "sport = :$1" 2>/dev/null)" ]]; }
# порты, которые часто заняты или выглядят подозрительно для DPI (WireGuard, OpenVPN, IPsec и т. п.)
BAD_PORTS=" 500 1194 1701 4500 51820 51821 39743 3478 5060 "
random_port() {
    local p
    for _ in $(seq 1 200); do
        p=$(( 20000 + $(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 40000 ))
        [[ "$BAD_PORTS" == *" $p "* ]] && continue
        udp_busy "$p" && continue
        echo "$p"; return 0
    done
    return 1
}

# ------------------------------------------------------------------ состояние
state_save() {
    mkdir -p "$AD_DIR"; chmod 700 "$AD_DIR"
    {
        printf 'PORT=%q\nPROTOCOL=%q\nENDPOINT=%q\nCLIENTS=%q\nMOBILE=%q\n' "$PORT" "$PROTOCOL" "$ENDPOINT" "$CLIENTS" "$MOBILE"
        printf 'EXTRA=('; printf '%q ' "${EXTRA[@]+"${EXTRA[@]}"}"; printf ')\n'
        printf 'PUBLIC_IP=%q\n' "${PUBLIC_IP:-}"
    } >"$AD_STATE.tmp"
    chmod 600 "$AD_STATE.tmp"; mv -f "$AD_STATE.tmp" "$AD_STATE"
}
state_load() {
    [[ -f "$AD_STATE" ]] || return 1
    # файл пишет только этот скрипт (printf %q), права 600, владелец root
    [[ "$(stat -c '%U %a' "$AD_STATE")" == "root 600" ]] || die "$AD_STATE: неверные права/владелец — не загружаю."
    # shellcheck disable=SC1090
    source "$AD_STATE"
}

self_install() { # копия обёртки в /usr/local/sbin, чтобы продолжить после перезагрузки
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    if [[ -f "$src" && "$src" != "$AD_BIN" ]]; then
        install -m 700 "$src" "$AD_BIN"
    elif [[ ! -x "$AD_BIN" ]]; then
        curl -fsSL --max-time 60 -o "$AD_BIN.new" "$AD_REPO_RAW/$AD_REF/autodeploy.sh" && chmod 700 "$AD_BIN.new" && mv -f "$AD_BIN.new" "$AD_BIN" \
            || die "Не удалось сохранить обёртку в $AD_BIN"
    fi
}
resume_unit_on() {
    cat >"$AD_UNIT" <<EOF
[Unit]
Description=amneziawg-autodeploy: продолжить установку после перезагрузки
After=network-online.target
Wants=network-online.target
ConditionPathExists=$AD_STATE

[Service]
Type=oneshot
ExecStart=$AD_BIN resume
StandardOutput=append:$AD_LOG
StandardError=append:$AD_LOG
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable awg-autodeploy-resume.service >/dev/null 2>&1
}
resume_unit_off() {
    systemctl disable awg-autodeploy-resume.service >/dev/null 2>&1 || true
    rm -f "$AD_UNIT"; systemctl daemon-reload || true
}

# ------------------------------------------------------------------ проверки до установки
preflight() {
    hdr "Проверка сервера"
    local id ver arch virt ram disk
    # shellcheck disable=SC1091
    . /etc/os-release
    id=$ID; ver=$VERSION_ID
    case "$id:$ver" in
        ubuntu:24.04|debian:13) ok "ОС: $PRETTY_NAME" ;;
        ubuntu:22.04|ubuntu:25.*|debian:12) warn "ОС $PRETTY_NAME: установщик её поддерживает, но обёртка проверена на Ubuntu 24.04 и Debian 13" ;;
        *) die "ОС $PRETTY_NAME не поддерживается. Нужна Ubuntu 24.04 LTS или Debian 13." ;;
    esac
    arch=$(uname -m)
    case "$arch" in
        x86_64|aarch64) ok "Архитектура: $arch" ;;
        *) die "Архитектура $arch не поддерживается (нужна x86_64 или arm64)." ;;
    esac
    virt=$(systemd-detect-virt 2>/dev/null || echo none)
    case "$virt" in
        lxc|openvz|docker|podman|wsl|systemd-nspawn) die "Виртуализация $virt — это контейнер: модуль ядра не поставить. Нужен KVM/VMware/Hyper-V/выделенный сервер." ;;
        *) ok "Виртуализация: $virt" ;;
    esac
    ok "Ядро: $(uname -r)"
    if [[ "$PROTOCOL" == "3.1" ]] && ! printf '%s\n%s\n' 6.7 "$(uname -r | cut -d- -f1)" | sort -VC; then
        warn "Ядро старее 6.7: AmneziaWG 3.1 здесь не поднять, установщик поставит 2.0 (или обнови ядро)"
    fi
    ram=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    ((ram >= 450)) && ok "RAM: ${ram} МБ" || die "RAM ${ram} МБ — мало (нужно от 512 МБ: сборка модуля через DKMS)."
    disk=$(df -Pm / | awk 'NR==2 {print $4}')
    ((disk >= 1500)) && ok "Свободно на диске: ${disk} МБ" || die "Свободно ${disk} МБ — нужно хотя бы 1,5 ГБ (заголовки ядра + DKMS)."
    [[ -c /dev/net/tun ]] && ok "/dev/net/tun есть (нужен только запасному amneziawg-go)" || warn "Нет /dev/net/tun: запасной вариант amneziawg-go не заработает (модулю ядра не нужен)"

    hdr "Конфликты"
    if ip -o link show type wireguard 2>/dev/null | grep -q .; then
        warn "Есть интерфейс WireGuard: $(ip -o link show type wireguard | awk -F': ' '{print $2}' | tr '\n' ' ')— проверь, что подсети и порты не пересекаются"
    else ok "WireGuard-интерфейсов нет"; fi
    if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        warn "Работает Docker: он сам правит iptables/FORWARD — проверь доступ клиентов после установки"
    else ok "Docker не запущен"; fi
    if [[ -f "$AWG_DIR/setup_state" ]]; then
        warn "Найдена начатая/выполненная установка AmneziaWG ($AWG_DIR/setup_state) — установщик продолжит её, ключи и клиенты сохранятся"
    fi
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        warn "На сервере работает 3x-ui: AWG встанет рядом, но порт 443/udp может быть занят Hysteria2"
    fi

    hdr "Сеть"
    getent hosts github.com >/dev/null || die "DNS не работает (не резолвится github.com)."
    ok "DNS работает"
    local u
    for u in https://raw.githubusercontent.com https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/ "$CH"; do
        curl -fsS -o /dev/null --max-time 15 "$u" 2>/dev/null || curl -sS -o /dev/null --max-time 15 "$u" 2>/dev/null \
            || { [[ "$u" == "$CH" ]] && { warn "Нет доступа к check-host.net — внешняя проверка будет пропущена"; SKIP_EXT=1; continue; }; die "Нет доступа к $u"; }
    done
    ok "Доступны GitHub и PPA Amnezia"
    PUBLIC_IP=$(detect_ip)
    [[ -n "$PUBLIC_IP" ]] || die "Не удалось определить публичный IPv4."
    local on_if=""
    for _ in 1 2 3 4 5; do   # сразу после загрузки DHCP может ещё переполучать адрес
        ip -4 -o addr show scope global | grep -qwF "$PUBLIC_IP" && { on_if=1; break; }
        sleep 2
    done
    if [[ -n "$on_if" ]]; then ok "Публичный IP: $PUBLIC_IP (на интерфейсе сервера)"
    else warn "Публичный IP $PUBLIC_IP не на интерфейсе — сервер за NAT: UDP-порт должен быть проброшен хостером"; fi
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then ok "Время синхронизировано (NTP)"
    else warn "Время не синхронизировано по NTP (timedatectl) — для AWG не критично, но проверь"; fi

    hdr "Порт AmneziaWG"
    if [[ -n "$PORT" ]]; then
        [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "PORT=$PORT — не порт."
        udp_busy "$PORT" && ! awg show awg0 listen-port 2>/dev/null | grep -qx "$PORT" && die "UDP-порт $PORT занят: $(ss -Hlunp "sport = :$PORT" | head -1)"
        ok "Порт задан: ${PORT}/udp"
    elif [[ "$MOBILE" == 1 ]]; then
        udp_busy 443 && die "443/udp занят (Hysteria2/HTTP3?) — для --mobile освободи его или задай --port=N"
        PORT=443; ok "Порт 443/udp (--mobile: мобильные операторы реже режут его как QUIC)"
    else
        PORT=$(random_port) || die "Не нашёл свободный UDP-порт"
        ok "Случайный порт: ${PORT}/udp (не стандартный 39743 — по нему легко найти сервер)"
    fi

    external_check
}

external_check() { # не заблокирован ли IP в России
    hdr "Доступность IP из России и Европы (check-host.net)"
    if [[ "$SKIP_EXT" == 1 ]]; then warn "Внешняя проверка пропущена"; return 0; fi
    local sp out ru w
    sp=$(ssh_port)
    if ! out=$(probe "$PUBLIC_IP" "$sp"); then warn "check-host.net не ответил — проверка пропущена"; return 0; fi
    read -r _ ru w <<<"$out"
    if [[ "$ru" == "?" || -z "${w:-}" ]]; then warn "Проверка не выполнилась (check-host.net)"; return 0; fi
    local ru_ok=${ru%/*} ru_all=${ru#*/} w_ok=${w%/*}
    if ((ru_ok > 0)); then
        ok "IP доступен из России (${ru}) и Европы (${w})"
    elif ((w_ok > 0 && ru_all > 0)); then
        fail "IP $PUBLIC_IP недоступен из России (${ru}), из Европы доступен (${w}) — похоже, он уже в блоке РКН"
        if [[ "$CMD" == install && "$ALLOW_BLOCKED" != 1 ]]; then
            die "Ставить VPN на заблокированный IP бессмысленно. Смени IP/сервер или запусти с --allow-blocked-ip."
        fi
    else
        warn "IP не отвечает ни из России, ни из Европы (${ru} / ${w}) на ${sp}/tcp — фаервол хостера? Сама установка не помешает"
    fi
}

# ------------------------------------------------------------------ установщик
fetch_installer() {
    local f="$AD_DIR/install_amneziawg.sh" src
    mkdir -p "$AD_DIR"; chmod 700 "$AD_DIR"
    src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo /)")/install_amneziawg.sh"
    if [[ -f "$src" && "$src" != "$f" ]]; then   # запуск из клона репозитория
        cp -f "$src" "$f.new"
    else
        curl -fsSL --max-time 120 -o "$f.new" "$AD_REPO_RAW/$AD_REF/install_amneziawg.sh" || die "Не удалось скачать install_amneziawg.sh"
    fi
    local got; got=$(sha256sum "$f.new" | awk '{print $1}')
    if [[ "$INSTALLER_SHA256" != "__INSTALLER_SHA256__" && "$got" != "$INSTALLER_SHA256" ]]; then
        rm -f "$f.new"
        die "SHA256 install_amneziawg.sh не совпал (ожидался $INSTALLER_SHA256, получен $got). Файл мог быть подменён."
    fi
    chmod 700 "$f.new"; mv -f "$f.new" "$f"
    log "    install_amneziawg.sh: SHA256 $got"
}

installer_args() {
    INST_ARGS=(--yes --keep-packages --allow-ipv6 --no-prebuilt --route-all "--port=$PORT" "--protocol=$PROTOCOL")
    [[ "$MOBILE" == 1 ]] && INST_ARGS+=(--preset=mobile)
    [[ -n "$ENDPOINT" ]] && INST_ARGS+=("--endpoint=$ENDPOINT")
    INST_ARGS+=("${EXTRA[@]+"${EXTRA[@]}"}")
}

run_installer() { # 0 — установка завершена; 2 — ушёл в перезагрузку
    installer_args
    hdr "Запуск install_amneziawg.sh ${INST_ARGS[*]}"
    local rc=0
    bash "$AD_DIR/install_amneziawg.sh" "${INST_ARGS[@]}" || rc=$?
    if [[ "$(cat "$AWG_DIR/setup_state" 2>/dev/null)" == "99" ]]; then
        return 0
    fi
    # установщик просит перезагрузку и выходит с 1 до reboot — продолжит systemd-юнит
    if [[ $rc -ne 0 ]] && grep -q 'ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА' "$AWG_DIR/install_amneziawg.log" 2>/dev/null \
        && [[ $(stat -c %Y "$AWG_DIR/install_amneziawg.log" 2>/dev/null || echo 0) -gt $(( $(date +%s) - 120 )) ]]; then
        return 2
    fi
    return "$rc"
}

manage() { bash "$AWG_DIR/manage_amneziawg.sh" "$@"; }

setup_clients() {
    [[ -n "$CLIENTS" ]] || return 0
    hdr "Клиенты: $CLIENTS"
    local c names=()
    IFS=',' read -ra names <<<"$CLIENTS"
    for c in "${names[@]}"; do
        c=${c//[[:space:]]/}
        [[ "$c" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { warn "Имя клиента «$c» пропущено (латиница, цифры, _ и -)"; continue; }
        if [[ -f "$AWG_DIR/$c.conf" ]]; then ok "$c уже есть"; continue; fi
        manage --yes add "$c" >/dev/null && ok "$c добавлен" || warn "Не удалось добавить $c (manage_amneziawg.sh add $c)"
    done
    for c in my_phone my_laptop; do   # клиенты по умолчанию установщика — убираем, если их не просили
        [[ ",${CLIENTS// /}," == *",$c,"* ]] && continue
        [[ -f "$AWG_DIR/$c.conf" ]] && manage --yes remove "$c" >/dev/null 2>&1 && ok "Клиент по умолчанию $c удалён"
    done
}

# ------------------------------------------------------------------ проверка после установки
post_check() {
    WARNS=0; FAILS=0
    hdr "Проверка AmneziaWG"
    [[ -f "$AD_STATE" ]] && state_load || true
    local lp
    systemctl is-active --quiet awg-quick@awg0 && ok "Сервис awg-quick@awg0 работает" || fail "Сервис awg-quick@awg0 не запущен (journalctl -u awg-quick@awg0)"
    lp=$(awg show awg0 listen-port 2>/dev/null || true)
    if [[ -n "$lp" ]]; then
        ok "Интерфейс awg0 поднят, порт ${lp}/udp"
        [[ -z "${PORT:-}" || "$lp" == "$PORT" ]] || warn "Слушает $lp, а в $AD_STATE записан $PORT"
        PORT=$lp
        [[ -n "$(ss -Hlun "sport = :$lp" 2>/dev/null)" ]] && ok "${lp}/udp слушается" || fail "${lp}/udp не слушается"
    else
        fail "Интерфейса awg0 нет (awg show)"
    fi
    if grep -q '^HeaderProtectionKey' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then ok "AWG 3.1: HeaderProtectionKey в конфиге"
    else ok "Профиль AWG 2.0"; fi
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]] && ok "IPv4 forwarding включён" || fail "net.ipv4.ip_forward = 0"
    if iptables -t nat -S 2>/dev/null | grep -q MASQUERADE || nft list ruleset 2>/dev/null | grep -q masquerade; then ok "NAT (MASQUERADE) есть"
    else fail "Нет NAT-правила MASQUERADE"; fi
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw status 2>/dev/null | grep -qE "^${PORT:-x}/udp" && ok "ufw: ${PORT}/udp открыт" || fail "ufw активен, но ${PORT:-?}/udp не разрешён"
        local sp; sp=$(ssh_port)
        ufw status 2>/dev/null | grep -qE "^(${sp}(/tcp)?|OpenSSH)\b" && ok "ufw: SSH ${sp}/tcp открыт" || warn "ufw: не вижу правила для SSH ${sp}/tcp — не закрывай текущую сессию, проверь вход"
    else
        warn "ufw выключен — сервер без фаервола"
    fi
    local n; n=$(awg show awg0 peers 2>/dev/null | grep -c . || true)
    ok "Клиентов (peers): ${n:-0}"
    if awg show awg0 latest-handshakes 2>/dev/null | awk '$2 > 0 {f=1} END {exit !f}'; then ok "Есть рукопожатия клиентов"
    else log "    [..] Рукопожатий пока нет — подключи клиента и запусти: awg-autodeploy check"; fi
    PUBLIC_IP=${PUBLIC_IP:-$(detect_ip)}
    external_check
    log ""
    log "Итог: ${FAILS} ошибок, ${WARNS} предупреждений. Подробная проверка установщика: bash $AWG_DIR/manage_amneziawg.sh check"
    ((FAILS == 0))
}

summary() {
    hdr "Готово"
    log "    Сервер:   ${PUBLIC_IP:-?}:${PORT}/udp, протокол AmneziaWG ${PROTOCOL}"
    log "    Конфиги:  $AWG_DIR/*.conf  (QR: $AWG_DIR/*.png)"
    log "    QR в терминале:   bash $AWG_DIR/manage_amneziawg.sh qr <имя>"
    log "    Новый клиент:     bash $AWG_DIR/manage_amneziawg.sh add <имя>"
    log "    Бэкап:            bash $AWG_DIR/manage_amneziawg.sh backup"
    log "    Проверка:         awg-autodeploy check"
    log "    Клиенты для 3.1: AmneziaWG (iOS/macOS 3.1.4+, Android 3.1.4+, Windows 3.1.0+), WG Tunnel 5.6+, Amnezia VPN 5.0.1.5+."
    log "    Роутеры GL.iNet на штатной прошивке и Hiddify 3.1 не понимают — для них отдельный сервер с --protocol=2.0."
}

# ------------------------------------------------------------------ команды
do_install() {
    need_root
    mkdir -p "$(dirname "$AD_LOG")"; touch "$AD_LOG"; chmod 600 "$AD_LOG"
    log "amneziawg-autodeploy v${AD_VERSION} ($(date '+%F %T'))"
    case "$PROTOCOL" in 3.1|2.0) ;; *) die "--protocol: 3.1 или 2.0" ;; esac
    command -v jq >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null 2>&1; } || die "Не удалось поставить jq"; }
    preflight

    hdr "План"
    installer_args
    log "    1. Скачать install_amneziawg.sh (pin SHA256) в $AD_DIR"
    log "    2. Запустить: install_amneziawg.sh ${INST_ARGS[*]}"
    log "       — обновит пакеты, подключит официальный PPA Amnezia (ключ с проверкой отпечатка),"
    log "         соберёт модуль через DKMS, включит ufw (SSH $(ssh_port)/tcp + ${PORT}/udp), fail2ban, NAT;"
    log "       — НЕ удаляет системные пакеты (--keep-packages), НЕ отключает IPv6 на хосте (--allow-ipv6),"
    log "         НЕ ставит готовые .deb модуля (--no-prebuilt)."
    log "       — 1–2 перезагрузки: после них установка продолжится сама (systemd awg-autodeploy-resume)."
    log "    3. Клиенты: ${CLIENTS:-my_phone, my_laptop (по умолчанию установщика)}"
    log "    4. Итоговая проверка. Лог: $AD_LOG"
    if ((DRY_RUN)); then log ""; log "--dry-run: ничего не изменено."; exit 0; fi
    ask "Выполнить?" || die "Отменено. Без вопросов: --yes"

    state_save
    self_install
    fetch_installer
    resume_unit_on
    local rc=0; run_installer || rc=$?
    case $rc in
        0) finish ;;
        2) log ""; log "Сервер перезагружается. Установка продолжится сама; через 3–5 минут зайди по SSH и выполни: awg-autodeploy status" ;;
        *) resume_unit_off; die "install_amneziawg.sh завершился с ошибкой ($rc). Лог: $AWG_DIR/install_amneziawg.log. Повторить: awg-autodeploy resume" ;;
    esac
}

do_resume() {
    need_root
    state_load || die "Нет $AD_STATE — нечего продолжать. Новая установка: awg-autodeploy install"
    log "Продолжение установки ($(date '+%F %T'))"
    # после перезагрузки сеть может подняться не сразу
    for _ in $(seq 1 30); do getent hosts github.com >/dev/null && break; sleep 2; done
    [[ -f "$AD_DIR/install_amneziawg.sh" ]] || fetch_installer
    local rc=0; run_installer || rc=$?
    case $rc in
        0) finish ;;
        2) log "Ещё одна перезагрузка — продолжу после неё." ;;
        *) resume_unit_off; log "install_amneziawg.sh: ошибка ($rc). Лог: $AWG_DIR/install_amneziawg.log. Повторить: awg-autodeploy resume"; exit "$rc" ;;
    esac
}

finish() {
    resume_unit_off
    setup_clients
    post_check || true
    summary
    echo "done $(date '+%F %T')" >"$AD_DIR/finished"
}

do_status() {
    if [[ -f "$AD_DIR/finished" ]]; then log "Установка завершена: $(cut -d' ' -f2- "$AD_DIR/finished")"; post_check || true; return; fi
    if systemctl is-enabled --quiet awg-autodeploy-resume.service 2>/dev/null; then
        log "Установка ещё идёт (шаг установщика: $(cat "$AWG_DIR/setup_state" 2>/dev/null || echo ?)). Последние строки лога:"
        tail -n 15 "$AD_LOG" 2>/dev/null || true
    else
        log "Установка не запущена или прервана. Лог: $AD_LOG; продолжить: awg-autodeploy resume"
        tail -n 15 "$AD_LOG" 2>/dev/null || true
    fi
}

case "$CMD" in
    help) usage ;;
    install) do_install ;;
    resume) do_resume ;;
    status) need_root; do_status ;;
    check) need_root; post_check ;;
esac
