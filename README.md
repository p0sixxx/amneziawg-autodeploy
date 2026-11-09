# awgctl — AmneziaWG одной командой

Установка своего VPN-сервера AmneziaWG 3.1 (или 2.0) и удобное управление пользователями, в стиле `vpn` из [3x-ui-autodeploy](https://github.com/p0sixxx/3x-ui-autodeploy).

Движок — [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) (MIT): модуль ядра через DKMS из официального PPA Amnezia, генерация параметров 3.1, клиенты, бэкапы. Его код не меняется: awgctl скачивает закреплённую версию (сейчас **v6.2.1**) и сверяет SHA256. Аудит — [AUDIT.md](AUDIT.md).

## Установка

Чистый VPS: Ubuntu 24.04, 26.04 или Debian 13, KVM (не контейнер), от 1 ядра и 1 ГБ RAM.

```bash
curl -fsSLo /root/awgctl https://raw.githubusercontent.com/p0sixxx/amneziawg-autodeploy/main/awgctl
bash /root/awgctl install --clients=phone,laptop
```

Вопросов нет. Сервер 1–2 раза перезагрузится, установка продолжится сама. Через 3–5 минут зайди по SSH:

```bash
awgctl status     # ход установки
awgctl list       # пользователи
awgctl show phone # QR и ссылка vpn://
```

Что делает `install`:

- проверяет сервер и сеть: ОС, архитектура, контейнер или ВМ, RAM, диск, DNS, доступ к GitHub и PPA, публичный IP, NAT, время, конфликты (WireGuard, Docker, 3x-ui);
- **проверяет, не заблокирован ли IP в России**: SSH-порт через check-host.net с узлов в РФ и Европе; на заблокированный IP не ставит;
- выбирает **случайный UDP-порт** 20000–59999 (у движка по умолчанию у всех 39743);
- настраивает как советует автор движка для однозадачного VPS: IPv6 на хосте выключен, лишние службы (snapd, packagekit, modemmanager, udisks2, unattended-upgrades…) удаляются, ufw + fail2ban, весь трафик в туннель, клиенты изолированы друг от друга;
- модуль ядра только из официального PPA (без готовых .deb из чужих релизов).

Параметры `install`:

| Параметр | Что |
|---|---|
| `--dry-run` | только проверки и план |
| `--clients=a,b` | пользователи сразу (иначе `my_phone`, `my_laptop`) |
| `--port=N` | свой порт вместо случайного |
| `--mobile` | 443/udp и пресет для мобильных операторов |
| `--protocol=2.0` | сервер для роутеров GL.iNet на штатной прошивке, Hiddify |
| `--endpoint=АДРЕС` | адрес для клиентов (домен, NAT) |
| `--keep-packages` / `--keep-ipv6` | не удалять службы / не выключать IPv6 |
| `--allow-blocked-ip` / `--skip-external-check` | ставить на IP, недоступный из РФ / не проверять |

## Пользователи

| Команда | Что |
|---|---|
| `awgctl add Ivan [--days 30] [--psk]` | новый пользователь: сразу QR, ссылка `vpn://` и файл |
| `awgctl list` | все: IP, вкл/выкл, сколько скачал и отдал, последний вход, срок |
| `awgctl show Ivan` | QR + ссылка + путь к конфигу |
| `awgctl qr Ivan` / `link Ivan` / `conf Ivan` | только QR / ссылка `vpn://` / текст конфига |
| `awgctl renew Ivan 30` | продлить на 30 дней от сегодня (`0` — бессрочно) |
| `awgctl off Ivan` / `on Ivan` | временно отключить / включить (ключи и конфиг те же) |
| `awgctl del Ivan` | удалить |

Как поделиться: ссылку из `awgctl link Ivan` открывают в **Amnezia VPN** или **AmneziaWG** («Вставить из буфера»), QR сканируют там же. Каждому человеку — свой пользователь: доступ отзывается у одного, не трогая остальных.

Срок (`--days`, `renew`): по истечении пользователь удаляется автоматически (cron движка). Трафик в `list` — с последнего запуска интерфейса awg0.

Клиенты, понимающие 3.1: AmneziaWG (iOS/macOS 3.1.4+, есть в российском App Store; Android 3.1.4+; Windows 3.1.0+), WG Tunnel 5.6+, Amnezia VPN 5.0.1.5+ (нет в российском App Store). Роутеры GL.iNet на штатной прошивке и Hiddify — только 2.0.

## Сервер

| Команда | Что |
|---|---|
| `awgctl check` | сервис, порт, NAT, ufw, рукопожатия, IP из России |
| `awgctl backup` / `restore [файл]` | бэкап ключей и пользователей / восстановление |
| `awgctl uninstall` | удалить AmneziaWG и awgctl |
| `awgctl engine <команда …>` | любая команда движка: `diagnose`, `stats`, `regen`, `restart`… |

| Порт | Что |
|---|---|
| SSH (текущий) /tcp | не меняется, разрешается в ufw до включения |
| случайный 20000–59999 /udp (или 443) | AmneziaWG |

Файлы: конфиги и QR — `/root/awg/`, сервер — `/etc/amnezia/amneziawg/awg0.conf`, awgctl — `/var/lib/awgctl/`, лог — `/var/log/awgctl.log`.

## Удаление

```bash
awgctl uninstall
```

Удаляет AmneziaWG встроенной командой движка (перед этим он делает бэкап), правила и службы awgctl, затем сам awgctl.

Проверка и тесты — [TESTING.md](TESTING.md).
