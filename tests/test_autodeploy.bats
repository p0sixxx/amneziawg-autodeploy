#!/usr/bin/env bats
# Тесты обёртки autodeploy.sh (amneziawg-autodeploy).

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "autodeploy: синтаксис и shellcheck" {
    bash -n "$ROOT/autodeploy.sh"
    if command -v shellcheck >/dev/null; then shellcheck "$ROOT/autodeploy.sh"; fi
}

@test "autodeploy: pin SHA256 совпадает с install_amneziawg.sh" {
    want=$(sha256sum "$ROOT/install_amneziawg.sh" | awk '{print $1}')
    run grep -c "^INSTALLER_SHA256=\"${want}\"" "$ROOT/autodeploy.sh"
    [ "$output" = "1" ]
}

@test "autodeploy: random_port не выдаёт известные порты и попадает в 20000-59999" {
    src=$(sed -n '/^BAD_PORTS=/,/^}/p' "$ROOT/autodeploy.sh")
    run bash -c "udp_busy() { return 1; }; $src
        for i in \$(seq 1 300); do p=\$(random_port); [[ \" \$BAD_PORTS \" == *\" \$p \"* ]] && exit 1; (( p >= 20000 && p <= 59999 )) || exit 2; done"
    [ "$status" -eq 0 ]
}

@test "autodeploy: установщик запускается с безопасными флагами" {
    run grep -E '^\s+INST_ARGS=\(--yes --keep-packages --allow-ipv6 --no-prebuilt' "$ROOT/autodeploy.sh"
    [ "$status" -eq 0 ]
}

@test "install: подмена AWG_BRANCH без AWG_ALLOW_UNVERIFIED — отказ проверки SHA" {
    fn=$(sed -n '/^verify_sha256() {/,/^}/p' "$ROOT/install_amneziawg.sh")
    tmp=$(mktemp); echo x >"$tmp"
    run bash -c "log_warn(){ :; }; log_error(){ :; }; log_debug(){ :; }; SCRIPT_VERSION=6.2.1; AWG_BRANCH=main; $fn
        verify_sha256 '$tmp' 0000 test"
    [ "$status" -eq 1 ]
    run bash -c "log_warn(){ :; }; log_error(){ :; }; log_debug(){ :; }; SCRIPT_VERSION=6.2.1; AWG_BRANCH=main; AWG_ALLOW_UNVERIFIED=1; $fn
        verify_sha256 '$tmp' 0000 test"
    [ "$status" -eq 0 ]
    rm -f "$tmp"
}

@test "autodeploy: неизвестный аргумент — ошибка" {
    run bash "$ROOT/autodeploy.sh" --bogus
    [ "$status" -ne 0 ]
}
