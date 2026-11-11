#!/usr/bin/env bats
# Тесты awgctl (без сервера: конфиг и awg — подделки).

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/awg/expiry"
    cat >"$T/awg0.conf" <<'CONF'
[Interface]
PrivateKey = x
ListenPort = 47213

[Peer]
#_Name = phone
PublicKey = PKphone=
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = Ivan-laptop
PublicKey = PKivan=
PresharedKey = psk=
AllowedIPs = 10.9.9.3/32, fddd::3/128
CONF
    now=$(date +%s)
    cat >"$T/bin/awg" <<STUB
#!/bin/sh
printf 'priv\tpub\t47213\toff\n'
printf 'PKphone=\t(none)\t1.2.3.4:5\t10.9.9.2/32\t$((now - 300))\t1048576\t5368709120\t0\n'
STUB
    chmod +x "$T/bin/awg"
    printf '#!/bin/sh\necho "manage $*" >>"%s/manage.log"\n' "$T" >"$T/bin/manage_amneziawg.sh"
    PATH="$T/bin:$PATH"
    # shellcheck disable=SC1091
    source "$ROOT/awgctl" help
    SERVER_CONF="$T/awg0.conf"; AWG_DIR="$T/awg"; AD_DIR="$T/ad"; OFF_LIST="$T/ad/disabled"; AD_LOG="$T/log"
    need_root() { :; }
    manage() { echo "manage $*" >>"$T/manage.log"; }
    cp "$T/bin/manage_amneziawg.sh" "$T/awg/manage_amneziawg.sh"
}

@test "awgctl: синтаксис, shellcheck, справка" {
    bash -n "$ROOT/awgctl"
    if command -v shellcheck >/dev/null; then shellcheck "$ROOT/awgctl"; fi
    run bash "$ROOT/awgctl" help
    [ "$status" -eq 0 ]; [[ "$output" == *"awgctl add"* ]]
}

@test "awgctl: неизвестная команда и параметр — ошибка" {
    run bash "$ROOT/awgctl" foo;    [ "$status" -ne 0 ]
    run bash "$ROOT/awgctl" --bogus; [ "$status" -ne 0 ]
}

@test "peers_tsv: имя, ключ, IP (PSK и IPv6 не мешают)" {
    run peers_tsv
    [ "${lines[0]}" = $'phone\tPKphone=\t10.9.9.2' ]
    [ "${lines[1]}" = $'Ivan-laptop\tPKivan=\t10.9.9.3' ]
    [ "$(client_ip Ivan-laptop)" = "10.9.9.3" ]
}

@test "human и ago" {
    [ "$(human 0)" = "0 Б" ]
    [ "$(human 1048576)" = "1.0 МБ" ]
    [ "$(human 5368709120)" = "5.0 ГБ" ]
    [ "$(ago 0)" = "—" ]
    [ "$(ago $(( $(date +%s) - 600 )))" = "10 мин назад" ]
}

@test "list: трафик с точки зрения клиента, вход, срок, выкл" {
    echo $(( $(date +%s) + 86400 * 10 )) >"$AWG_DIR/expiry/phone"
    mkdir -p "$AD_DIR"; echo Ivan-laptop >"$OFF_LIST"
    run do_list
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" == phone*10.9.9.2*вкл*"5.0 ГБ"*"1.0 МБ"*"5 мин назад"* ]]
    [[ "${lines[1]}" == *"$(date -d "@$(cat "$AWG_DIR/expiry/phone")" '+%d.%m.%Y')" ]]
    [[ "${lines[2]}" == Ivan-laptop*ВЫКЛ*"0 Б"*"—"*"∞" ]]
}

@test "add: --days передаётся как --expires, имя проверяется" {
    run bash -c "source '$ROOT/awgctl' help; check_name 'bad name'"
    [ "$status" -ne 0 ]
    POS=(newuser); DAYS=30
    do_show() { :; }
    client_exists() { [ "$1" != newuser ]; }
    run do_add
    grep -q -- "manage --yes --expires=30d add newuser" "$T/manage.log"
}

@test "renew: дни и бессрочно" {
    POS=(phone 7)
    run do_renew; [ "$status" -eq 0 ]
    exp=$(cat "$AWG_DIR/expiry/phone")
    [ $(( exp - $(date +%s) )) -ge $(( 7 * 86400 - 5 )) ]
    POS=(phone 0)
    run do_renew; [ ! -f "$AWG_DIR/expiry/phone" ]
}

@test "off/on: список отключённых и правила" {
    rules_persist() { :; }; rules_apply() { :; }
    POS=(phone); do_off >/dev/null
    is_off phone
    do_off >/dev/null; [ "$(grep -c '^phone$' "$OFF_LIST")" = 1 ]
    do_on >/dev/null
    ! is_off phone
}

@test "del: неизвестный пользователь — ошибка" {
    POS=(nobody); AUTO_YES=1
    run do_del
    [ "$status" -ne 0 ]
}

@test "установщик: безопасные и быстрые флаги, движок с SHA256" {
    PORT=40000; PROTOCOL=3.1; MOBILE=0; ENDPOINT=""; SRV_NAME=""; KEEP_PKGS=0; KEEP_IPV6=0; EXTRA=()
    installer_args
    [[ " ${INST_ARGS[*]} " == *" --yes "* && " ${INST_ARGS[*]} " == *" --no-prebuilt "* ]]
    [[ " ${INST_ARGS[*]} " == *" --disallow-ipv6 "* ]]
    [[ " ${INST_ARGS[*]} " != *" --keep-packages "* ]]
    SRV_NAME="My server"; installer_args
    [[ " ${INST_ARGS[*]} " == *" --server-name=My server "* ]]
    KEEP_PKGS=1; KEEP_IPV6=1; installer_args
    [[ " ${INST_ARGS[*]} " == *" --keep-packages "* && " ${INST_ARGS[*]} " == *" --allow-ipv6 "* ]]
    [[ "$ENGINE_SHA256" =~ ^[0-9a-f]{64}$ ]]
    [[ "$ENGINE_URL" == https://github.com/bivlked/amneziawg-installer/releases/download/v${ENGINE_VER}/install_amneziawg.sh ]]
}

@test "random_port: 20000-59999 и не известные порты" {
    udp_busy() { return 1; }
    for _ in $(seq 1 200); do
        p=$(random_port)
        [[ " $BAD_PORTS " != *" $p "* ]]
        (( p >= 20000 && p <= 59999 ))
    done
}

@test "дополнения: без терминала по умолчанию не ставятся, флаги сохраняются" {
    WANT_ADBLOCK=""; WANT_BOT=""
    ask_extras </dev/null
    [ "$WANT_ADBLOCK" = 0 ] && [ "$WANT_BOT" = 0 ]
    WANT_ADBLOCK=1; WANT_BOT=""
    ask_extras </dev/null
    [ "$WANT_ADBLOCK" = 1 ]
}

@test "bot: неверный токен или ID — отказ до скачивания" {
    need_installed() { :; }
    TG_TOKEN="bad"; TG_ADMINS="123"
    run do_bot; [ "$status" -ne 0 ]; [[ "$output" == *"Токен"* ]]
    TG_TOKEN="123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; TG_ADMINS="abc"
    run do_bot; [ "$status" -ne 0 ]; [[ "$output" == *"Telegram ID"* ]]
}

@test "закреплённые версии дополнений" {
    [[ "$AWGRAM_SETUP_SHA256" =~ ^[0-9a-f]{64}$ && "$BLOCKY_SHA256_X86_64" =~ ^[0-9a-f]{64}$ && "$BLOCKY_SHA256_ARM64" =~ ^[0-9a-f]{64}$ ]]
    [[ "$ADBLOCK_REPO" =~ /[0-9a-f]{40}$ ]]
    for f in $ADBLOCK_FILES; do [[ "${f#*:}" =~ ^[0-9a-f]{64}$ ]]; done
}

@test "state: пустой EXTRA не превращается в пустой аргумент (и старые файлы чинятся)" {
    AD_STATE="$T/state.env"; PORT=1; PROTOCOL=3.1; ENDPOINT=""; CLIENTS=""; MOBILE=0; KEEP_PKGS=0; KEEP_IPV6=0
    SRV_NAME=""; WANT_ADBLOCK=0; WANT_BOT=0; TG_TOKEN=""; TG_ADMINS=""; EXTRA=()
    AD_DIR="$T/st"; state_save
    grep -qx 'EXTRA=()' "$AD_STATE"
    sed -i "s/^EXTRA=.*/EXTRA=('' )/" "$AD_STATE"
    stat() { echo "root 600"; }
    state_load
    [ "${#EXTRA[@]}" -eq 0 ]
    installer_args
    for a in "${INST_ARGS[@]}"; do [ -n "$a" ]; done
}

@test "обфускация QUIC: формат I1-I5, уникальность, --i1 у движка" {
    for _ in $(seq 1 50); do
        x=$(gen_quic_cps)
        [[ "$x" =~ ^\<b\ 0xc[0-3]00000001[0-9a-f]{2}[0-9a-f]+\>\<rc\ [0-9]+\>\<t\>\<r\ [0-9]+\>$ ]]
        [[ "$x" != *"<c>"* ]]
    done
    OBFS=quic; CPS_I1=""; gen_cps_set
    [ -n "$CPS_I5" ] && [ "$CPS_I1" != "$CPS_I2" ]
    first=$CPS_I1; gen_cps_set; [ "$CPS_I1" = "$first" ]   # при продолжении не меняются
    PORT=1; PROTOCOL=3.1; MOBILE=0; ENDPOINT=""; SRV_NAME=""; KEEP_PKGS=0; KEEP_IPV6=0; EXTRA=()
    installer_args
    [[ " ${INST_ARGS[*]} " == *" --i1=$CPS_I1 "* ]]
    OBFS=engine; installer_args
    [[ " ${INST_ARGS[*]} " != *"--i1="* ]]
}

@test "обфускация QUIC: I1-I5 заменяют прежние после H4, init движка обновляется" {
    printf '[Interface]\nPrivateKey = x\nH4 = 4\nI1 = <b 0xdead>\nHeaderProtectionKey = k\n\n[Peer]\n#_Name = a\nI1 = чужое\n' >"$SERVER_CONF"
    printf "export AWG_I1='<b 0xdead>'\nexport AWG_I2=''\n" >"$AWG_DIR/awgsetup_cfg.init"
    OBFS=quic; CPS_I1="<b 0x01>"; CPS_I2="<b 0x02>"; CPS_I3="<b 0x03>"; CPS_I4="<b 0x04>"; CPS_I5="<b 0x05>"
    obfs_apply >/dev/null
    run sed -n '3,9p' "$SERVER_CONF"
    [ "${lines[0]}" = "H4 = 4" ] && [ "${lines[1]}" = "I1 = <b 0x01>" ] && [ "${lines[5]}" = "I5 = <b 0x05>" ] && [ "${lines[6]}" = "HeaderProtectionKey = k" ]
    ! grep -q 'dead' "$SERVER_CONF"
    grep -q '^I1 = чужое' "$SERVER_CONF"   # секции [Peer] не трогаются
    grep -qx "export AWG_I2='<b 0x02>'" "$AWG_DIR/awgsetup_cfg.init"
    grep -qx "export AWG_I1_PIN='<b 0x01>'" "$AWG_DIR/awgsetup_cfg.init"
    [ "$(grep -c '^export AWG_I2=' "$AWG_DIR/awgsetup_cfg.init")" = 1 ]
    grep -q "manage --yes regen" "$T/manage.log"
    obfs_apply >/dev/null; [ "$(grep -c '^I2 = ' "$SERVER_CONF")" = 1 ]   # повторно не дублирует
}

@test "bot: ID с пробелами, \\r и невидимыми символами из буфера принимаются" {
    need_installed() { :; }
    fetch_pinned() { return 1; }   # дальше проверки не идём
    TG_TOKEN=$' 123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\r'; TG_ADMINS=$'204004858,\u200b 922458929\r'
    run do_bot
    [[ "$output" == *"Не удалось скачать установщик awgram"* ]]
}
