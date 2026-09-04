# Remnawave Server Protect

Безопасная базовая настройка Linux-сервера для **Remnawave Panel / Remnawave Node / Xray-core**.

Скрипт предназначен для серверов, на которых работает Remnawave Node или Panel, и выполняет системную настройку TCP/IP, локального зашифрованного DNS, nftables, Fail2ban и лимитов файловых дескрипторов.

Основная цель — получить стабильную конфигурацию сервера для Remnawave без вмешательства в конфигурацию Xray, Docker-сети и настройки Node.

> **Важно:** скрипт не является гарантией обхода блокировок или DPI. Он выполняет системное hardening и переводит DNS с обычного UDP/53 на локальный DNS-over-HTTPS.

## Поддерживаемая конфигурация

Целевая конфигурация:

* Remnawave Panel: `3.4.x`
* Remnawave Node: `3.4.1`
* Xray-core: `26.7.28`
* Docker Engine + Docker Compose
* Ubuntu 22.04 / 24.04
* Debian 12
* архитектуры `amd64`, `arm64`, `armhf` для cloudflared

Remnawave Node представляет собой отдельный контейнер, внутри которого работает Xray-core. Panel и Node являются раздельными компонентами Remnawave.

Xray-core `26.7.28` доступен в официальном репозитории XTLS/Xray-core.

---

# Возможности

## 1. TCP/IP hardening

Скрипт создаёт:

```text
/etc/sysctl.d/99-remnawave-server.conf
```

Настраиваются:

* IPv4 forwarding;
* IPv6 forwarding;
* TCP timestamps;
* TCP SACK;
* TCP window scaling;
* TCP MTU probing;
* TCP SYN cookies;
* TCP connection queues;
* TCP buffers;
* `tcp_tw_reuse`;
* `tcp_rfc1337`;
* уменьшение TCP FIN timeout;
* отключение ICMP redirects;
* отключение source routing;
* базовое ICMP hardening.

При этом настройки подобраны таким образом, чтобы не вмешиваться в работу Docker и Remnawave Node.

### BBR

Скрипт не навязывает конкретный congestion control.

Если сервер уже использует BBR, текущая конфигурация не отключает необходимые TCP timestamps.

Проверить congestion control:

```bash
sysctl net.ipv4.tcp_congestion_control
```

---

# 2. DNS-over-HTTPS

Это одна из главных особенностей скрипта.

Вместо прямого использования:

```text
8.8.8.8:53
1.1.1.1:53
```

создаётся локальный DNS-over-HTTPS proxy.

Архитектура:

```text
                 Linux / Docker / applications
                            │
                            ▼
                    systemd-resolved
                            │
                            ▼
                     127.0.0.1:5053
                            │
                            ▼
                       cloudflared
                            │
                    HTTPS / TCP 443
                       ┌────┴────┐
                       ▼         ▼
                  Cloudflare   Quad9
                     DoH         DoH
```

`cloudflared` работает только на:

```text
127.0.0.1:5053
```

и не открывает DNS-сервис наружу.

Upstream:

```text
https://cloudflare-dns.com/dns-query
https://dns.quad9.net/dns-query
```

Таким образом, сервер не отправляет DNS-запросы к публичным DNS-серверам в открытом UDP/53.

### Почему это важно

Обычный DNS:

```text
Client
  │
  └──── UDP/53 ────> 8.8.8.8
```

не шифруется.

Новая схема:

```text
Client
  │
  └──── HTTPS/443 ────> DoH resolver
```

DNS-запрос находится внутри HTTPS-соединения.

### Важный момент

Скрипт **не считает 8.8.8.8 и 1.1.1.1 недоступными всегда**.

Он только перестаёт зависеть от их обычного UDP/53.

При этом меню содержит диагностический тест:

```text
Plain UDP/53:

8.8.8.8:53
1.1.1.1:53

Local encrypted resolver:

127.0.0.1:5053
```

Это позволяет определить, проходит ли обычный DNS с конкретного сервера.

---

# 3. Не изменяет DNS внутри Xray

Скрипт не редактирует:

```text
Xray config
inbounds
outbounds
routing
dns
realitySettings
xhttpSettings
```

Это сделано намеренно.

Remnawave управляет конфигурацией Node и передаёт конфигурацию Xray через Panel. Поэтому системный hardening не должен перезаписывать конфигурацию Xray.

---

# 4. Docker compatibility

Скрипт не изменяет:

* Docker bridge;
* Docker NAT;
* Docker Compose Remnawave;
* `network_mode`;
* порты Node;
* конфигурацию `remnanode`;
* Xray configuration.

Это особенно важно для Remnawave Node.

Официальная документация Remnawave показывает Node как отдельный контейнер Docker, обычно использующий `network_mode: host`.

---

# 5. File descriptor limits

Для серверов с большим количеством одновременных соединений устанавливается:

```text
nofile = 1048576
```

Создаются:

```text
/etc/security/limits.d/99-remnawave.conf
/etc/systemd/system/docker.service.d/limits.conf
```

Это увеличивает доступное количество файловых дескрипторов для Docker/systemd.

Docker автоматически не перезапускается.

После изменения конфигурации администратор может самостоятельно выполнить:

```bash
systemctl restart docker
```

Это сделано специально, чтобы скрипт неожиданно не отключал работающий Remnawave Node.

---

# 6. nftables

Создаётся отдельная таблица:

```text
inet remnawave_protect
```

Файл:

```text
/etc/nftables.d/remnawave-protect.nft
```

В неё добавляются только базовые ICMP-фильтры.

Скрипт намеренно **не устанавливает**:

```text
TTL spoofing
SYN rate limit
RST drop
Docker forwarding restrictions
```

## Почему нет TTL=128

Принудительная установка:

```text
TTL = 128
```

для всего исходящего трафика может менять сетевое поведение и не является универсальным способом защиты от DPI.

Поэтому TTL normalization оставлен за пределами базовой конфигурации.

## Почему нет SYN-limit

В старом варианте использовалось:

```text
200 SYN/sec
```

Для публичного Node это слишком произвольное значение.

При большом количестве пользователей такое ограничение может привести к отбрасыванию легитимных подключений.

Поэтому SYN rate-limit отключён.

---

# 7. Fail2ban

Устанавливается Fail2ban и создаётся jail для SSH:

```text
/etc/fail2ban/jail.d/remnawave-sshd.local
```

Стандартные параметры:

```text
5 попыток
10 минут
бан 1 час
```

Fail2ban используется только для защиты SSH.

Проверка:

```bash
fail2ban-client status sshd
```

Разбан IP:

```bash
fail2ban-client set sshd unbanip IP_ADDRESS
```

---

# 8. Backup

Перед изменением конфигурации создаётся backup:

```text
/root/remnawave-protect-backups/YYYYMMDD-HHMMSS/
```

Сохраняются, если существуют:

```text
/etc/sysctl.d/99-remnawave-server.conf
/etc/systemd/resolved.conf.d/remnawave-doh.conf
/etc/resolv.conf
/etc/nftables.conf
/etc/nftables.d/remnawave-protect.nft
/etc/docker/daemon.json
/etc/security/limits.d/99-remnawave.conf
/etc/systemd/system/docker.service.d/limits.conf
/etc/systemd/system/remnawave-server-protect.service
/etc/fail2ban/jail.d/remnawave-sshd.local
```

Это позволяет вернуть предыдущую конфигурацию.

---

# 9. Rollback

В меню есть:

```text
10) Восстановить последний backup
```

Скрипт находит последний backup и восстанавливает сохранённые файлы.

После восстановления перезапускаются соответствующие системные сервисы.

---

# 10. Проверка Remnawave

Скрипт не изменяет Node автоматически.

Он обнаруживает Docker-контейнеры и пытается найти:

```text
remnawave
remnanode
node
```

Выводится:

```text
container name
image
status
```

Например:

```text
[Node candidate] remnanode
  image : remnawave/node:3.4.1
  state : Up ...
  version: Node 3.4.1 detected
```

Официальная документация Remnawave также рекомендует использовать контейнер `remnanode` и Docker Compose для запуска Node.

---

# Меню

После запуска отображается:

```text
============================================================
 Remnawave Server Protect
 Panel 3.4.x | Node 3.4.1 | Xray 26.7.28
============================================================

  1) SYSCTL baseline
  2) nftables (без TTL/SYN-limit)
  3) File descriptor limits
  4) DNS-over-HTTPS (local cloudflared)
  5) Fail2ban SSH
  6) Проверить DNS
  7) Проверить Remnawave/Docker
  8) Установить всё рекомендуемое
  9) Статус
 10) Восстановить последний backup
 11) Бенчмарк DNS + выбор 2 лучших
```

Для обычной установки достаточно:

```text
8
```

---

# Установка

Скачать скрипт:

```bash
wget -O remnawave-server-protect.sh https://github.com/win64exe/rkn_protect/raw/refs/heads/main/remnawave-server-protect.sh && chmod +x remnawave-server-protect.sh && sudo ./remnawave-server-protect.sh
```

И выбрать:

```text
8) Установить всё рекомендуемое
```

---

# После установки

Проверить DNS:

```bash
resolvectl status
```

Проверить локальный DoH proxy:

```bash
dig example.com @127.0.0.1
```

Проверить cloudflared:

```bash
systemctl status dnsproxy
```

Логи:

```bash
journalctl -u dnsproxy -n 100 --no-pager
```

Проверить nftables:

```bash
nft list table inet remnawave_protect
```

Проверить Fail2ban:

```bash
fail2ban-client status sshd
```

Проверить Docker:

```bash
docker ps
```

Проверить Node:

```bash
docker logs --tail 100 remnanode
```

Для просмотра Xray Core logs Remnawave предоставляет команду:

```bash
docker exec remnanode xlogs
```

---

# Важное замечание по Node Port

`NODE_PORT` / `APP_PORT` Node не должен быть открыт для всего интернета.

Официальная документация Remnawave рекомендует разрешать доступ к Node Port только с IP-адреса Panel.

Например:

```text
Panel IP
    │
    └──── TCP:APP_PORT ────> Remnawave Node

Internet
    │
    └──── TCP:APP_PORT ────> BLOCK
```

Настройка firewall для конкретного `APP_PORT` намеренно не выполняется автоматически, поскольку IP Panel и порт Node различаются на каждом сервере.

---

# Что скрипт НЕ делает

Скрипт не:

* изменяет Xray config;
* создаёт VLESS пользователей;
* изменяет Reality keys;
* изменяет XHTTP;
* изменяет CDN;
* изменяет Nginx;
* устанавливает или обновляет Remnawave Panel;
* обновляет Remnawave Node;
* заменяет Xray-core внутри Node;
* изменяет Docker Compose;
* меняет Docker network;
* автоматически открывает Node Port;
* устанавливает TTL spoofing;
* блокирует TCP RST;
* гарантирует обход DPI/блокировок.

Это **серверный hardening + encrypted DNS**, а не DPI-bypass инструмент.

---

# Почему именно такой подход

Remnawave Node отвечает за проксирование пользовательского трафика через Xray-core, поэтому вмешательство в Docker networking или автоматическое изменение конфигурации Node может привести к потере связи между Panel и Node.

Поэтому скрипт разделяет уровни:

```text
┌──────────────────────────────────────┐
│           Remnawave Panel            │
└──────────────────────────────────────┘
                    │
                    │ Node API
                    ▼
┌──────────────────────────────────────┐
│          Remnawave Node              │
│                                      │
│             Xray-core                │
└──────────────────────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────┐
│            Linux kernel              │
│                                      │
│ sysctl / nftables / TCP / DNS / F2B │
└──────────────────────────────────────┘
```

Скрипт работает преимущественно на нижнем уровне и не пытается управлять Remnawave/Xray.

---

# Безопасность

Перед использованием на production-сервере рекомендуется:

1. Открыть вторую SSH-сессию.
2. Создать резервную копию.
3. Запустить скрипт.
4. Проверить DNS.
5. Проверить Docker.
6. Проверить `remnanode`.
7. Проверить связь Node с Panel.
8. Только после этого закрывать старую SSH-сессию.

Особенно внимательно проверяйте SSH после включения Fail2ban и изменения firewall.

---

# License

MIT License

Copyright (c) 2026

Разрешается свободное использование, изменение и распространение проекта при сохранении текста лицензии.
