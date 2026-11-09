# Аудит bivlked/amneziawg-installer v6.2.1

Дата проверки: 9 ноября 2026. Основа форка: тег `v6.2.1`, коммит `4eed2dd` (06.11.2026), лицензия MIT.

## Компоненты, которые ставит установщик

| Компонент | Откуда | Версия на дату проверки | Проверка подлинности |
|---|---|---|---|
| amneziawg-dkms, amneziawg-tools | `ppa:amnezia/ppa` (ppa.launchpadcontent.net) | модуль v3.1.20260906 (4569c4c), tools v3.1.20260812 (ee0f0a9) | ключ PPA встроен в установщик, отпечаток `75C9DD72C799870E310542E24166F2C257290828` сверяется перед записью в keyring; источник `deb [signed-by=…]`, без `apt-key` |
| awg_common.sh, manage_amneziawg.sh | raw.githubusercontent.com/bivlked/amneziawg-installer/v6.2.1 | v6.2.1 | SHA256-pin в install_amneziawg.sh (`COMMON_SCRIPT_SHA256`, `MANAGE_SCRIPT_SHA256`); тест `test_v515_sha_pins_lockstep.bats` проходит |
| install_amneziawg.sh | этот репозиторий | форк v6.2.1 + правки ниже | SHA256-pin в autodeploy.sh (`INSTALLER_SHA256`), тест `test_autodeploy.bats` |
| Модуль 2.0 (ядра < 6.7) | git clone amnezia-vpn/amneziawg-linux-kernel-module | закреплённый коммит `ae0924ca…` (`AWG2_PIN_COMMIT`) | сверка коммита после clone |
| Готовые .deb модуля для ARM | релиз `arm-packages` автора bivlked | — | **только SHA256 из того же релиза** — подлинность не проверяется (см. находку 2) |

## Что проверено

- Все сетевые обращения (`curl`, `wget`, `git clone`) в install/common/manage: GitHub автора (скрипты, ARM-пакеты), PPA Amnezia, git модуля Amnezia, сервисы определения IP (ipify, icanhazip, ifconfig.me и др.). Телеметрии и отправки данных о сервере нет. `wget …/v$want/…` в manage — только печатаемая подсказка, не выполняется.
- `eval`/`source` внешних данных: конфиги читаются белым списком ключей («без source/eval»).
- Ключи: приватные ключи, PSK и `HeaderProtectionKey` в `/root/awg` и `/etc/amnezia/amneziawg` с правами 600; в логах маскируются (`[HIDDEN]`).
- Параметры 3.1 (`generate_awg_params`): `HeaderProtectionKey` — случайные 32 байта на сервер; H1–H4 = 1,2,3,4 при Header Protection; S1–S4 ≥ 12 (модуль ядра иначе вернёт `-EINVAL`, проверено в `netlink.c`: `HEADER_PROTECTION_NONCE_SIZE = 12`); исключены коллизии длин (S1+56≠S2, S2+28≠S3, S4 по таблице). `RandomTrailers`/`DisableCookies` по умолчанию выключены. I1 (CPS) — случайный DNS-подобный пакет на каждый сервер, не пример из документации.
- Фаервол: ufw, SSH-порт определяется (ss / sshd -T / sshd_config) и разрешается до `ufw enable`.
- Защита от CVE в apt (запрет повторов скачивания на время установки) и от CVE-2026-98432 (правило против TCP с IP-опциями).

## Находки и что сделано в форке

| # | Находка | Риск | Решение |
|---|---|---|---|
| 1 | Переменная окружения `AWG_BRANCH`, отличная от тега, **молча отключала** проверку SHA256 скачиваемых awg_common.sh/manage_amneziawg.sh (только предупреждение в лог) | подмена кода, который выполняется от root | `verify_sha256` теперь отказывает; обойти можно только явным `AWG_ALLOW_UNVERIFIED=1` (RU и EN). Тест в `tests/test_autodeploy.bats` |
| 2 | На ARM по умолчанию ставится готовый .deb модуля ядра из релиза автора; SHA256 скачивается из того же места | целостность, но не подлинность: модуль ядра от третьей стороны | обёртка всегда передаёт `--no-prebuilt` — модуль только из официального PPA через DKMS |
| 3 | По умолчанию установщик удаляет snapd, unattended-upgrades, modemmanager, cloud-init и др. (с согласием) | расходится с требованием «не удалять Snap, unattended-upgrades, сетевые службы» | обёртка передаёт `--keep-packages` |
| 4 | По умолчанию отключает IPv6 на хосте глобально | расходится с требованием «не отключать IPv6 глобально» | обёртка передаёт `--allow-ipv6`: IPv6 хоста не трогается, IPv6-адресов в туннеле нет (это отдельный флаг `--allow-ipv6-tunnel`). В режиме «весь трафик» у клиентов в AllowedIPs есть `::/0`, поэтому их IPv6 уходит в туннель и там не маршрутизируется — мимо VPN не утекает (проверка — в TESTING.md) |
| 5 | Порт по умолчанию 39743/udp одинаков у всех установок | сервер легко найти сканированием | обёртка выбирает случайный порт 20000–59999 (или 443 при `--mobile`) |
| 6 | Нет проверки, не заблокирован ли IP сервера в РФ | VPN ставится на уже бесполезный IP | обёртка проверяет SSH-порт через check-host.net из РФ и Европы и останавливается, если IP недоступен только из РФ |
| 7 | `ContentPaddingAddition` 32–128 в профиле 3.1 | sing-box-extended падает при значении > 16 (issue #158 у sing-box-extended) | не меняли: официальные клиенты работают; для sing-box задать вручную |

## Чего аудит не покрывает

Установщик — около 40 тыс. строк bash. Проверялись все места с сетью, правами, ключами, apt, фаерволом и генерацией параметров; бизнес-логика шагов (resume, restore, cascade, WARP) построчно не проверялась. Перед обновлением форка на новую версию upstream — повторить проверку по этому списку (`git diff v6.2.1..vNEW -- install_amneziawg.sh awg_common.sh manage_amneziawg.sh`, затем `scripts/update-autodeploy-pin.sh`).
