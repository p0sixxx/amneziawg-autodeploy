# Проверка amneziawg-autodeploy

## Локально (без сервера)

```bash
bash -n autodeploy.sh && shellcheck autodeploy.sh
bats tests/test_autodeploy.bats            # обёртка: pin, порт, флаги, отказ без SHA
bats tests/test_v515_sha_pins_lockstep.bats # pin скриптов upstream
bats --jobs 8 tests/                       # весь набор upstream (~3200 тестов)
```

После любой правки `install_amneziawg.sh`: `scripts/update-autodeploy-pin.sh`.

## На сервере

| Что | Команда | Ожидается |
|---|---|---|
| План без изменений | `bash /root/awg-autodeploy.sh --dry-run` | все `[OK]`, план, «ничего не изменено» |
| Ход установки после перезагрузок | `awg-autodeploy status` | «Установка завершена» или текущий шаг |
| Итоговая проверка | `awg-autodeploy check` | 0 ошибок |
| Подробная проверка установщика | `bash /root/awg/manage_amneziawg.sh check` | без FAIL |
| Сервис и интерфейс | `systemctl status awg-quick@awg0`, `awg show awg0` | active, `listening port` = порт из установки |
| Forwarding и NAT | `sysctl net.ipv4.ip_forward`, `iptables -t nat -S \| grep MASQUERADE` | `= 1`, правило есть |
| Фаервол и SSH | `ufw status verbose` | открыты SSH и `<порт>/udp`; **проверь вход по SSH в новом окне, не закрывая старое** |
| После перезагрузки | `reboot`, затем `awg-autodeploy check` | то же, правила на месте |
| Рукопожатие | подключить клиента, `awg show awg0 latest-handshakes` | ненулевое время у клиента |
| Выход в интернет | на клиенте открыть 2ip.ru / `curl -4 ifconfig.me` | IP сервера |
| DNS | на клиенте `nslookup example.com` | отвечает |
| Утечка IPv6 | на клиенте test-ipv6.com / `curl -6 ifconfig.me` | IPv6 недоступен (не твой реальный адрес) |
| MTU | на клиенте `ping -M do -s 1252 1.1.1.1` (Linux/macOS: `-D`) | проходит; если нет — `manage_amneziawg.sh diagnose` |
| Блокировка IP в РФ | `awg-autodeploy check` (раздел check-host.net) | «IP доступен из России» |

UDP-порт снаружи проверить нельзя: AmneziaWG молчит на чужие пакеты. Его доступность подтверждает только рукопожатие клиента.
