#!/usr/bin/env bash
# ================================================================
# remnawave-server-protect.sh
#
# Server baseline for:
#   Remnawave Panel 3.4.x
#   Remnawave Node 3.4.1
#   Xray-core 26.7.28
#
# Tested target: Ubuntu 22.04/24.04, Debian 12
#
# IMPORTANT:
#   This script does NOT modify Xray configs, Remnawave Node compose,
#   Docker networks, or application ports.
#
#   DNS is moved away from plain UDP/53 to a local DNS-over-HTTPS
#   proxy (cloudflared) + systemd-resolved. This avoids relying on
#   plain DNS queries to 8.8.8.8/1.1.1.1.
#
# Run as root:
#   bash remnawave-server-protect.sh
# ================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
BACKUP_ROOT="/root/remnawave-protect-backups"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
title() { echo -e "\n${CYAN}==== $* ====${NC}"; }

[[ $EUID -eq 0 ]] || error "Запустите скрипт от root."

mkdir -p "$BACKUP_DIR"

cleanup_on_error() {
    local rc=$?
    if (( rc != 0 )); then
        warn "Скрипт завершился с ошибкой (код ${rc})."
        warn "Резервная копия: ${BACKUP_DIR}"
    fi
}
trap cleanup_on_error EXIT

backup_file() {
    local f="$1"
    [[ -e "$f" || -L "$f" ]] || return 0
    mkdir -p "${BACKUP_DIR}$(dirname "$f")"
    cp -a "$f" "${BACKUP_DIR}${f}"
}

detect_os() {
    [[ -r /etc/os-release ]] || error "Не найден /etc/os-release."
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *) warn "ОС ${PRETTY_NAME:-unknown} не тестировалась. Продолжаю." ;;
    esac

    info "ОС: ${PRETTY_NAME:-unknown}"
}

backup_all() {
    title "BACKUP"

    backup_file /etc/sysctl.d/99-remnawave-server.conf
    backup_file /etc/systemd/resolved.conf.d/remnawave-doh.conf
    backup_file /etc/resolv.conf
    backup_file /etc/nftables.conf
    backup_file /etc/nftables.d/remnawave-protect.nft
    backup_file /etc/docker/daemon.json
    backup_file /etc/security/limits.d/99-remnawave.conf
    backup_file /etc/systemd/system/docker.service.d/limits.conf
    backup_file /etc/systemd/system/remnawave-server-protect.service
    backup_file /etc/fail2ban/jail.d/remnawave-sshd.local

    info "Backup создан: ${BACKUP_DIR}"
}

install_packages() {
    title "PACKAGES"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    local packages=(
        curl
        ca-certificates
        nftables
        fail2ban
        dnsutils
        iproute2
        procps
    )

    apt-get install -y "${packages[@]}" >/dev/null

    info "Базовые пакеты установлены."
}

apply_sysctl() {
    title "SYSCTL"

    cat > /etc/sysctl.d/99-remnawave-server.conf <<'EOF'
# Remnawave/Xray server baseline

# IPv4/IPv6 forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1

# SYN protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_synack_retries = 5

# TIME_WAIT / FIN
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# TIME_WAIT/RST handling
net.ipv4.tcp_rfc1337 = 1

# Socket queues
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768

# Reasonable TCP memory ceilings
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Redirect/source-route hardening
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_source_route = 0

net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# ICMP noise reduction
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 0
EOF

    sysctl --system >/dev/null

    info "sysctl применён."
}

configure_fd_limits() {
    title "FILE DESCRIPTORS"

    cat > /etc/security/limits.d/99-remnawave.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system/docker.service.d

    cat > /etc/systemd/system/docker.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF

    systemctl daemon-reload

    info "Лимит NOFILE для Docker/systemd установлен: 1048576."
    warn "Docker НЕ перезапускаю автоматически."
    warn "После проверки конфигурации можно выполнить: systemctl restart docker"
}

install_cloudflared() {
    title "DNS OVER HTTPS"

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || true)"

    local cf_arch=""
    case "$arch" in
        amd64) cf_arch="amd64" ;;
        arm64) cf_arch="arm64" ;;
        armhf) cf_arch="armhf" ;;
        *) error "Неподдерживаемая архитектура для cloudflared: ${arch}" ;;
    esac

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"

    info "Скачиваю cloudflared (${cf_arch})..."
    curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp/cloudflared"

    install -m 0755 "$tmp/cloudflared" /usr/local/bin/cloudflared

    /usr/local/bin/cloudflared --version || error "cloudflared не запускается."

    info "cloudflared установлен."
}

configure_doh() {
    title "LOCAL ENCRYPTED DNS"

    if ! command -v cloudflared >/dev/null 2>&1; then
        install_cloudflared
    fi

    mkdir -p /etc/systemd/system/cloudflared-dns.service.d
    mkdir -p /etc/systemd/resolved.conf.d

    # Local listener only. No public DNS service is exposed.
    cat > /etc/systemd/system/cloudflared-dns.service <<'EOF'
[Unit]
Description=Local DNS-over-HTTPS proxy for Remnawave server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared proxy-dns \
    --address 127.0.0.1 \
    --port 5053 \
    --no-autoupdate \
    --upstream https://cloudflare-dns.com/dns-query \
    --upstream https://dns.quad9.net/dns-query
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/run
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # systemd-resolved sends DNS to local DoH proxy.
    cat > /etc/systemd/resolved.conf.d/remnawave-doh.conf <<'EOF'
[Resolve]
DNS=127.0.0.1#5053
FallbackDNS=
DNSOverTLS=no
DNSSEC=no
Domains=~.
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
EOF

    # Save current resolv.conf before replacing it.
    backup_file /etc/resolv.conf

    systemctl daemon-reload
    systemctl enable --now cloudflared-dns.service

    sleep 2

    if ! systemctl is-active --quiet cloudflared-dns.service; then
        error "cloudflared-dns.service не запустился. Проверьте: journalctl -u cloudflared-dns.service -n 100"
    fi

    systemctl restart systemd-resolved

    # Prefer the standard resolved stub.
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    sleep 2

    info "Проверяю локальный DNS..."
    if ! dig +short +time=4 +tries=2 example.com @127.0.0.53 >/dev/null; then
        warn "127.0.0.53 не ответил. Проверяю cloudflared напрямую..."
        if ! dig +short +time=4 +tries=2 example.com @127.0.0.1 -p 5053 >/dev/null; then
            error "Локальный DoH DNS не отвечает."
        fi
    fi

    info "Encrypted DNS работает."
    warn "8.8.8.8 и 1.1.1.1 НЕ используются как plain DNS upstream."
}

test_dns() {
    title "DNS TEST"

    echo
    echo "Plain UDP/53 (diagnostic only):"

    for ip in 8.8.8.8 1.1.1.1; do
        if timeout 3 dig +short +tries=1 +time=2 example.com "@${ip}" >/dev/null 2>&1; then
            echo -e "  ${ip}:53 UDP  ${GREEN}OK${NC}"
        else
            echo -e "  ${ip}:53 UDP  ${YELLOW}FAIL/filtered${NC}"
        fi
    done

    echo
    echo "Local encrypted resolver:"

    if dig +short +tries=2 +time=3 example.com @127.0.0.1 -p 5053 >/dev/null 2>&1; then
        echo -e "  127.0.0.1:5053 DoH  ${GREEN}OK${NC}"
    else
        echo -e "  127.0.0.1:5053 DoH  ${RED}FAIL${NC}"
        return 1
    fi

    if getent ahosts example.com >/dev/null 2>&1; then
        echo -e "  system resolver      ${GREEN}OK${NC}"
    else
        echo -e "  system resolver      ${RED}FAIL${NC}"
        return 1
    fi

    echo
}

apply_nftables() {
    title "NFTABLES"

    command -v nft >/dev/null 2>&1 || error "nft не найден."

    mkdir -p /etc/nftables.d

    cat > /etc/nftables.d/remnawave-protect.nft <<'EOF'
table inet remnawave_protect {

    chain input {
        type filter hook input priority 10; policy accept;

        # Drop ICMP timestamp/address-mask requests.
        ip protocol icmp icmp type {
            timestamp-request,
            address-mask-request
        } drop

        # IPv6 MLDv2 reports / listener done.
        ip6 nexthdr icmpv6 icmpv6 type { 139, 140 } drop
    }
}
EOF

    # Do not install a SYN rate limit and do not rewrite TTL by default.
    # Docker/Remnawave networking is intentionally left untouched.

    if [[ -f /etc/nftables.conf ]] && ! grep -Fq 'remnawave-protect.nft' /etc/nftables.conf; then
        echo 'include "/etc/nftables.d/remnawave-protect.nft"' >> /etc/nftables.conf
    fi

    # Replace only our own table.
    nft delete table inet remnawave_protect 2>/dev/null || true
    nft -f /etc/nftables.d/remnawave-protect.nft

    systemctl enable nftables >/dev/null 2>&1 || true

    info "nftables применён."
    warn "TTL spoofing отключён по умолчанию."
    warn "SYN rate-limit отключён по умолчанию."
}

configure_fail2ban() {
    title "FAIL2BAN"

    command -v fail2ban-client >/dev/null 2>&1 || {
        apt-get install -y fail2ban >/dev/null
    }

    mkdir -p /etc/fail2ban/jail.d

    local ssh_port
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    ssh_port="${ssh_port:-22}"

    cat > /etc/fail2ban/jail.d/remnawave-sshd.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban
    sleep 2

    if fail2ban-client status sshd >/dev/null 2>&1; then
        info "Fail2ban: sshd jail активен."
    else
        warn "sshd jail не активен. Проверьте: fail2ban-client status sshd"
    fi
}

detect_remnawave() {
    title "REMNAWAVE / DOCKER CHECK"

    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker не установлен."
        return 0
    fi

    echo
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
    echo

    local found=0

    while read -r name image status; do
        [[ -n "$name" ]] || continue

        if [[ "$name" =~ remnawave|remnanode|node ]]; then
            found=1
            echo -e "${GREEN}[Node candidate]${NC} ${name}"
            echo "  image : ${image}"
            echo "  state : ${status}"

            if [[ "$image" == *remnawave*node* ]]; then
                if [[ "$image" == *3.4.1* ]]; then
                    echo -e "  version: ${GREEN}Node 3.4.1 detected${NC}"
                else
                    echo -e "  version: ${YELLOW}check image tag${NC}"
                fi
            fi

            echo
        fi
    done < <(docker ps --format '{{.Names}} {{.Image}} {{.Status}}')

    (( found == 1 )) || warn "Remnawave Node-контейнер автоматически не найден."
}

install_service() {
    title "SYSTEMD"

    cat > /etc/systemd/system/remnawave-server-protect.service <<'EOF'
[Unit]
Description=Remnawave server network baseline
After=network-online.target nftables.service cloudflared-dns.service
Wants=network-online.target
Requires=cloudflared-dns.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sysctl --system >/dev/null && nft delete table inet remnawave_protect 2>/dev/null || true; nft -f /etc/nftables.d/remnawave-protect.nft'
ExecStop=/bin/bash -c 'nft delete table inet remnawave_protect 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable remnawave-server-protect.service >/dev/null
    systemctl start remnawave-server-protect.service

    info "systemd service установлен."
}

show_status() {
    title "STATUS"

    echo
    echo "=== Versions ==="
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared --version || true
    fi

    echo
    echo "=== DNS ==="
    resolvectl status 2>/dev/null | sed -n '1,45p' || true

    echo
    echo "=== Services ==="
    systemctl is-active cloudflared-dns.service || true
    systemctl is-active systemd-resolved || true
    systemctl is-active fail2ban || true

    echo
    echo "=== nftables ==="
    nft list table inet remnawave_protect 2>/dev/null || true

    echo
    echo "=== TCP congestion ==="
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true

    echo
    echo "=== Docker ==="
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true

    echo
    echo "=== DNS functional test ==="
    test_dns || true
}

restore_last_backup() {
    title "RESTORE"

    local latest
    latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1 || true)"

    [[ -n "$latest" ]] || {
        warn "Backup не найден."
        return
    }

    echo "Последний backup: $latest"
    read -r -p "Восстановить его? [y/N]: " answer
    [[ "${answer,,}" == "y" ]] || return

    for f in \
        /etc/sysctl.d/99-remnawave-server.conf \
        /etc/systemd/resolved.conf.d/remnawave-doh.conf \
        /etc/resolv.conf \
        /etc/nftables.conf \
        /etc/nftables.d/remnawave-protect.nft \
        /etc/docker/daemon.json \
        /etc/security/limits.d/99-remnawave.conf \
        /etc/systemd/system/docker.service.d/limits.conf \
        /etc/systemd/system/remnawave-server-protect.service \
        /etc/fail2ban/jail.d/remnawave-sshd.local
    do
        if [[ -e "${latest}${f}" || -L "${latest}${f}" ]]; then
            mkdir -p "$(dirname "$f")"
            rm -f "$f"
            cp -a "${latest}${f}" "$f"
        fi
    done

    systemctl daemon-reload || true
    sysctl --system >/dev/null 2>&1 || true
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true

    info "Backup восстановлен."
    warn "Проверьте DNS и Docker вручную."
}

menu() {
    clear || true

    echo "============================================================"
    echo " Remnawave Server Protect"
    echo " Panel 3.4.x | Node 3.4.1 | Xray 26.7.28"
    echo "============================================================"
    echo
    echo "  1) SYSCTL baseline"
    echo "  2) nftables (без TTL/SYN-limit)"
    echo "  3) File descriptor limits"
    echo "  4) DNS-over-HTTPS (local cloudflared)"
    echo "  5) Fail2ban SSH"
    echo "  6) Проверить DNS"
    echo "  7) Проверить Remnawave/Docker"
    echo "  8) Установить всё рекомендуемое"
    echo "  9) Статус"
    echo " 10) Восстановить последний backup"
    echo
    read -r -p "Ваш выбор [8]: " choice

    case "${choice:-8}" in
        1) apply_sysctl ;;
        2) apply_nftables ;;
        3) configure_fd_limits ;;
        4) configure_doh ;;
        5) configure_fail2ban ;;
        6) test_dns ;;
        7) detect_remnawave ;;
        8)
            detect_os
            backup_all
            install_packages
            apply_sysctl
            configure_fd_limits
            apply_nftables
            configure_doh
            configure_fail2ban
            install_service
            detect_remnawave
            test_dns
            show_status
            ;;
        9) show_status ;;
        10) restore_last_backup ;;
        *) error "Неверный выбор." ;;
    esac
}

detect_os
menu

echo
info "Готово."
echo "Backup: ${BACKUP_DIR}"
echo
echo "Полезные команды:"
echo "  systemctl status cloudflared-dns"
echo "  journalctl -u cloudflared-dns -n 100 --no-pager"
echo "  resolvectl status"
echo "  dig example.com @127.0.0.1 -p 5053"
echo "  docker ps"
echo "  docker logs --tail 100 <remnawave-node-container>"
echo "  nft list table inet remnawave_protect"
echo
