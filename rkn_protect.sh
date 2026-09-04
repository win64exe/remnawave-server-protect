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
#   proxy (AdGuard dnsproxy) + systemd-resolved. This avoids relying
#   on plain DNS queries to 8.8.8.8/1.1.1.1.
#
#   Note: cloudflared proxy-dns was removed in 2026.2.0, so we use
#   dnsproxy instead.
#
# Run as root:
#   bash remnawave-server-protect.sh
# ================================================================
set -Eeuo pipefail
IFS=$'\n\t'
SCRIPT_NAME="$(basename "$0")"
BACKUP_ROOT="/root/remnawave-protect-backups"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
DOH_CONFIG="/etc/remnawave-doh-upstreams.conf"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

# ----------------------------------------------------------------
# Known DoH endpoints for popular public resolvers
# ----------------------------------------------------------------
declare -A DOH_MAP=(
    ["1.1.1.1"]="https://cloudflare-dns.com/dns-query"
    ["1.0.0.1"]="https://cloudflare-dns.com/dns-query"
    ["9.9.9.9"]="https://dns.quad9.net/dns-query"
    ["149.112.112.112"]="https://dns.quad9.net/dns-query"
    ["208.67.222.222"]="https://doh.opendns.com/dns-query"
    ["208.67.220.220"]="https://doh.opendns.com/dns-query"
    ["8.8.8.8"]="https://dns.google/dns-query"
    ["8.8.4.4"]="https://dns.google/dns-query"
    ["185.228.168.9"]="https://doh.cleanbrowsing.org/doh/security-filter/"
    ["185.228.169.9"]="https://doh.cleanbrowsing.org/doh/security-filter/"
    ["76.76.2.0"]="https://freedns.controld.com/p0"
    ["76.76.10.0"]="https://freedns.controld.com/p0"
    ["94.140.14.14"]="https://dns.adguard-dns.com/dns-query"
    ["94.140.15.15"]="https://dns.adguard-dns.com/dns-query"
    # Yandex DNS (basic)
    ["77.88.8.8"]="https://common.dot.dns.yandex.net/dns-query"
    ["77.88.8.1"]="https://common.dot.dns.yandex.net/dns-query"
    # Yandex DNS (safe)
    ["77.88.8.88"]="https://safe.dot.dns.yandex.net/dns-query"
    ["77.88.8.2"]="https://safe.dot.dns.yandex.net/dns-query"
    # Yandex DNS (family)
    ["77.88.8.7"]="https://family.dot.dns.yandex.net/dns-query"
    ["77.88.8.3"]="https://family.dot.dns.yandex.net/dns-query"
)

# Full list of DNS servers to benchmark
DNS_LIST=(
    1.0.0.1
    1.1.1.1
    134.195.4.2
    149.112.112.112
    159.89.120.99
    185.228.168.9
    185.228.169.9
    195.46.39.39
    195.46.39.40
    205.171.2.65
    205.171.3.65
    208.67.220.220
    208.67.222.222
    216.146.35.35
    216.146.36.36
    64.6.64.6
    64.6.65.6
    74.82.42.42
    76.76.10.0
    76.76.2.0
    77.88.8.1
    77.88.8.8
    8.20.247.20
    8.26.56.26
    8.8.4.4
    8.8.8.8
    84.200.69.80
    84.200.70.40
    89.233.43.71
    9.9.9.9
    91.239.100.100
)

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
    backup_file "$DOH_CONFIG"
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

install_dnsproxy() {
    title "DNS OVER HTTPS (dnsproxy)"
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    local dp_arch=""
    case "$arch" in
        amd64) dp_arch="amd64" ;;
        arm64) dp_arch="arm64" ;;
        armhf|armv7l) dp_arch="armv7" ;;
        *) error "Неподдерживаемая архитектура для dnsproxy: ${arch}" ;;
    esac

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    # Fetch latest release tag and asset
    local api_url="https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest"
    local tag asset_url
    tag="$(curl -fsSL --retry 3 --connect-timeout 10 "$api_url" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)"
    [[ -n "$tag" ]] || error "Не удалось получить версию dnsproxy."
    asset_url="https://github.com/AdguardTeam/dnsproxy/releases/download/${tag}/dnsproxy-linux-${dp_arch}-${tag}.tar.gz"

    info "Скачиваю dnsproxy ${tag} (${dp_arch})..."
    curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$tmp/dnsproxy.tar.gz"
    tar -xzf "$tmp/dnsproxy.tar.gz" -C "$tmp"
    # Archive contains linux-*/dnsproxy
    local bin
    bin="$(find "$tmp" -type f -name dnsproxy | head -1)"
    [[ -n "$bin" && -x "$bin" ]] || error "Бинарник dnsproxy не найден в архиве."
    install -m 0755 "$bin" /usr/local/bin/dnsproxy
    /usr/local/bin/dnsproxy --version || error "dnsproxy не запускается."
    info "dnsproxy установлен."
}

# ----------------------------------------------------------------
# DNS Benchmark
# ----------------------------------------------------------------
benchmark_dns() {
    title "DNS BENCHMARK"
    command -v dig >/dev/null 2>&1 || {
        warn "dig не найден — устанавливаю dnsutils..."
        apt-get update -qq
        apt-get install -y dnsutils >/dev/null
    }

    local domain="example.com"
    local tries=3
    local timeout_sec=2
    local results=()          # "avg|success|min|max|ip"
    local total=${#DNS_LIST[@]}
    local i=0

    echo
    info "Тестирую ${total} DNS-серверов (query: ${domain}, ${tries} попытки, timeout ${timeout_sec}s)..."
    echo
    printf "%-18s %8s %8s %8s %8s\n" "IP" "avg_ms" "ok" "min" "max"
    printf "%-18s %8s %8s %8s %8s\n" "------------------" "--------" "--------" "--------" "--------"

    for ip in "${DNS_LIST[@]}"; do
        i=$((i + 1))
        local times=()
        local success=0
        local t
        for ((t=1; t<=tries; t++)); do
            local qtime
            qtime=$(timeout $((timeout_sec + 1)) dig +time=${timeout_sec} +tries=1 +stats "${domain}" @"${ip}" 2>/dev/null \
                | awk '/Query time:/ {print $4}' || true)
            if [[ -n "$qtime" && "$qtime" =~ ^[0-9]+$ ]]; then
                times+=("$qtime")
                success=$((success + 1))
            fi
        done

        if (( success > 0 )); then
            local sum=0 min=${times[0]} max=${times[0]}
            for t in "${times[@]}"; do
                sum=$((sum + t))
                if (( t < min )); then min=$t; fi
                if (( t > max )); then max=$t; fi
            done
            local avg=$((sum / success))
            printf "%-18s %8s %8s %8s %8s\n" "$ip" "$avg" "${success}/${tries}" "$min" "$max"
            results+=("${avg}|${success}|${min}|${max}|${ip}")
        else
            printf "%-18s %8s %8s %8s %8s\n" "$ip" "FAIL" "0/${tries}" "-" "-"
        fi
    done

    echo
    if (( ${#results[@]} == 0 )); then
        warn "Ни один DNS не ответил. Проверьте сеть."
        return 1
    fi

    # Sort by avg ascending, then by success descending
    local sorted
    mapfile -t sorted < <(printf '%s\n' "${results[@]}" | sort -t'|' -k1,1n -k2,2nr)

    echo -e "${BOLD}=== ТОП по latency ===${NC}"
    printf "%-4s %-18s %8s %8s %8s %8s  %s\n" "#" "IP" "avg_ms" "ok" "min" "max" "DoH"
    printf "%-4s %-18s %8s %8s %8s %8s  %s\n" "----" "------------------" "--------" "--------" "--------" "--------" "----"

    local rank=0
    local top_ips=()
    for line in "${sorted[@]}"; do
        rank=$((rank + 1))
        IFS='|' read -r avg success min max ip <<< "$line"
        local doh_mark="-"
        [[ -n "${DOH_MAP[$ip]:-}" ]] && doh_mark="${GREEN}yes${NC}"
        printf "%-4s %-18s %8s %8s %8s %8s  %b\n" "$rank" "$ip" "$avg" "${success}/${tries}" "$min" "$max" "$doh_mark"
        top_ips+=("$ip")
        if (( rank >= 10 )); then break; fi
    done

    echo
    # Suggest top-2 that have known DoH, otherwise just top-2
    local sug1="" sug2=""
    for ip in "${top_ips[@]}"; do
        if [[ -n "${DOH_MAP[$ip]:-}" ]]; then
            if [[ -z "$sug1" ]]; then
                sug1="$ip"
            elif [[ -z "$sug2" && "$ip" != "$sug1" ]]; then
                # Prefer different providers
                local doh1="${DOH_MAP[$sug1]}"
                local doh2="${DOH_MAP[$ip]}"
                if [[ "$doh1" != "$doh2" ]]; then
                    sug2="$ip"
                    break
                fi
            fi
        fi
    done
    # Fallback if not enough DoH-capable
    if [[ -z "$sug1" ]]; then sug1="${top_ips[0]}"; fi
    if [[ -z "$sug2" && ${#top_ips[@]} -ge 2 ]]; then
        for ip in "${top_ips[@]}"; do
            [[ "$ip" != "$sug1" ]] && { sug2="$ip"; break; }
        done
    fi

    # Ensure we always have two suggestions
    if [[ -z "$sug1" ]]; then sug1="${top_ips[0]:-1.1.1.1}"; fi
    if [[ -z "$sug2" ]]; then sug2="${top_ips[1]:-9.9.9.9}"; fi

    echo -e "${BOLD}Рекомендация (с учётом наличия DoH):${NC}"
    echo -e "  1) ${GREEN}${sug1}${NC}  →  ${DOH_MAP[$sug1]:-plain UDP only}"
    echo -e "  2) ${GREEN}${sug2}${NC}  →  ${DOH_MAP[$sug2]:-plain UDP only}"
    echo

    # Interactive selection (safe under set -e / non-tty)
    local sel1="$sug1" sel2="$sug2"
    if [[ -t 0 ]]; then
        local input1 input2
        read -r -p "Выберите 1-й DNS (Enter = ${sug1}): " input1 || true
        [[ -n "${input1:-}" ]] && sel1="$input1"
        read -r -p "Выберите 2-й DNS (Enter = ${sug2}): " input2 || true
        [[ -n "${input2:-}" ]] && sel2="$input2"
    else
        info "stdin не интерактивный — беру рекомендацию автоматически."
    fi

    # Validate against DNS_LIST
    local valid1=0 valid2=0
    for ip in "${DNS_LIST[@]}"; do
        [[ "$ip" == "$sel1" ]] && valid1=1
        [[ "$ip" == "$sel2" ]] && valid2=1
    done
    if (( valid1 == 0 )); then
        warn "IP ${sel1} нет в списке. Использую рекомендацию."
        sel1="$sug1"
    fi
    if (( valid2 == 0 )); then
        warn "IP ${sel2} нет в списке. Использую рекомендацию."
        sel2="$sug2"
    fi

    local doh1="${DOH_MAP[$sel1]:-}"
    local doh2="${DOH_MAP[$sel2]:-}"

    if [[ -z "$doh1" && -z "$doh2" ]]; then
        warn "У выбранных IP нет известных DoH-эндпоинтов."
        warn "Будут использованы дефолтные Cloudflare + Quad9."
        doh1="https://cloudflare-dns.com/dns-query"
        doh2="https://dns.quad9.net/dns-query"
        sel1="1.1.1.1"
        sel2="9.9.9.9"
    elif [[ -z "$doh1" ]]; then
        warn "${sel1} не имеет DoH — беру только ${sel2} + Cloudflare."
        doh1="https://cloudflare-dns.com/dns-query"
        sel1="1.1.1.1"
    elif [[ -z "$doh2" ]]; then
        warn "${sel2} не имеет DoH — беру только ${sel1} + Quad9."
        doh2="https://dns.quad9.net/dns-query"
        sel2="9.9.9.9"
    fi

    # Save selection
    cat > "$DOH_CONFIG" <<EOF
# Generated by remnawave-server-protect.sh on $(date -Iseconds)
# Selected DNS IPs (for reference)
PRIMARY_IP=${sel1}
SECONDARY_IP=${sel2}
# DoH upstreams for dnsproxy
PRIMARY_DOH=${doh1}
SECONDARY_DOH=${doh2}
EOF
    chmod 644 "$DOH_CONFIG"

    echo
    info "Выбрано и сохранено в ${DOH_CONFIG}:"
    echo -e "  Primary   : ${GREEN}${sel1}${NC} → ${doh1}"
    echo -e "  Secondary : ${GREEN}${sel2}${NC} → ${doh2}"
    echo
    info "Теперь можно запускать пункт 4 (DNS-over-HTTPS) — он подхватит этот выбор."
}

load_doh_upstreams() {
    # Returns two DoH URLs via global vars PRIMARY_DOH SECONDARY_DOH
    PRIMARY_DOH="https://cloudflare-dns.com/dns-query"
    SECONDARY_DOH="https://dns.quad9.net/dns-query"

    if [[ -f "$DOH_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$DOH_CONFIG"
        PRIMARY_DOH="${PRIMARY_DOH:-https://cloudflare-dns.com/dns-query}"
        SECONDARY_DOH="${SECONDARY_DOH:-https://dns.quad9.net/dns-query}"
        info "Использую сохранённые upstreams: ${PRIMARY_IP:-?} + ${SECONDARY_IP:-?}"
    else
        info "Файл выбора DNS не найден — использую Cloudflare + Quad9 по умолчанию."
        info "Запустите пункт 11 (Бенчмарк DNS) чтобы выбрать лучшие для этого VPS."
    fi
}

configure_doh() {
    title "LOCAL ENCRYPTED DNS"
    # Stop/remove old cloudflared proxy-dns if present (removed upstream since 2026.2.0)
    if systemctl list-unit-files 2>/dev/null | grep -q 'cloudflared-dns.service'; then
        systemctl disable --now cloudflared-dns.service 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared-dns.service
        systemctl daemon-reload 2>/dev/null || true
        warn "Старый cloudflared-dns отключён (proxy-dns удалён в 2026.2.0)."
    fi
    # Also stop any leftover cloudflared dns-proxy process
    if pgrep -f 'cloudflared.*proxy-dns' >/dev/null 2>&1; then
        pkill -f 'cloudflared.*proxy-dns' 2>/dev/null || true
        warn "Остановлен процесс cloudflared proxy-dns."
    fi

    if ! command -v dnsproxy >/dev/null 2>&1; then
        install_dnsproxy
    fi

    load_doh_upstreams

    mkdir -p /etc/systemd/resolved.conf.d

    # Local listener only. No public DNS service is exposed.
    # dnsproxy: -l listen, -p port, -u upstream(s), --cache, -b bootstrap
    cat > /etc/systemd/system/dnsproxy.service <<EOF
[Unit]
Description=Local DNS-over-HTTPS proxy (dnsproxy) for Remnawave server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnsproxy \\
    -l 127.0.0.1 \\
    -p 5053 \\
    -u ${PRIMARY_DOH} \\
    -u ${SECONDARY_DOH} \\
    -b 1.1.1.1:53 \\
    -b 8.8.8.8:53 \\
    --cache \\
    --cache-size 4096 \\
    --ratelimit 0
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
    systemctl enable --now dnsproxy.service
    sleep 2
    if ! systemctl is-active --quiet dnsproxy.service; then
        error "dnsproxy.service не запустился. Проверьте: journalctl -u dnsproxy.service -n 100"
    fi
    systemctl restart systemd-resolved
    # Prefer the standard resolved stub.
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    sleep 2
    info "Проверяю локальный DNS..."
    if ! dig +short +time=4 +tries=2 example.com @127.0.0.53 >/dev/null; then
        warn "127.0.0.53 не ответил. Проверяю dnsproxy напрямую..."
        if ! dig +short +time=4 +tries=2 example.com @127.0.0.1 -p 5053 >/dev/null; then
            error "Локальный DoH DNS не отвечает."
        fi
    fi
    info "Encrypted DNS работает (dnsproxy)."
    info "Upstreams: ${PRIMARY_DOH} + ${SECONDARY_DOH}"
    warn "Plain UDP/53 к публичным DNS больше не используется системой."
}

test_dns() {
    title "DNS TEST"
    echo
    echo "Plain UDP/53 (diagnostic only):"
    for ip in 8.8.8.8 1.1.1.1 9.9.9.9; do
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
    if [[ -f "$DOH_CONFIG" ]]; then
        echo
        echo "Saved selection:"
        cat "$DOH_CONFIG"
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
After=network-online.target nftables.service dnsproxy.service
Wants=network-online.target
Requires=dnsproxy.service
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
    if command -v dnsproxy >/dev/null 2>&1; then
        dnsproxy --version || true
    fi
    echo
    echo "=== DNS ==="
    resolvectl status 2>/dev/null | sed -n '1,45p' || true
    echo
    if [[ -f "$DOH_CONFIG" ]]; then
        echo "=== Selected DoH upstreams ==="
        cat "$DOH_CONFIG"
        echo
    fi
    echo "=== Services ==="
    systemctl is-active dnsproxy.service || true
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
        /etc/fail2ban/jail.d/remnawave-sshd.local \
        "$DOH_CONFIG"
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
    echo "  4) DNS-over-HTTPS (local dnsproxy)"
    echo "  5) Fail2ban SSH"
    echo "  6) Проверить DNS"
    echo "  7) Проверить Remnawave/Docker"
    echo "  8) Установить всё рекомендуемое"
    echo "  9) Статус"
    echo " 10) Восстановить последний backup"
    echo " 11) Бенчмарк DNS + выбор 2 лучших"
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
            # If no selection yet — run benchmark first
            if [[ ! -f "$DOH_CONFIG" ]]; then
                warn "Выбор DNS ещё не сделан. Запускаю бенчмарк..."
                benchmark_dns
            fi
            configure_doh
            configure_fail2ban
            install_service
            detect_remnawave
            test_dns
            show_status
            ;;
        9) show_status ;;
        10) restore_last_backup ;;
        11) benchmark_dns ;;
        *) error "Неверный выбор." ;;
    esac
}

run_rkn_protect() {
    title "RKN PROTECT"
    local url="https://github.com/win64exe/rkn_protect/raw/refs/heads/main/rkn_protect.sh"
    local dest="/root/rkn_protect.sh"
    info "Скачиваю rkn_protect.sh..."
    if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$dest"; then
        warn "Не удалось скачать rkn_protect.sh — пропускаю."
        return 0
    fi
    chmod +x "$dest"
    info "Запускаю rkn_protect.sh (выбор 8)..."
    # Feed menu choice 8 non-interactively
    if echo "8" | bash "$dest"; then
        info "rkn_protect.sh завершён."
    else
        warn "rkn_protect.sh завершился с ошибкой (код $?). Проверьте вручную: bash $dest"
    fi
}

detect_os
menu
echo
info "Готово."
echo "Backup: ${BACKUP_DIR}"
echo
echo "Полезные команды:"
echo "  systemctl status dnsproxy"
echo "  journalctl -u dnsproxy -n 100 --no-pager"
echo "  resolvectl status"
echo "  dig example.com @127.0.0.1 -p 5053"
echo "  cat $DOH_CONFIG"
echo "  docker ps"
echo "  docker logs --tail 100 <remnawave-node-container>"
echo "  nft list table inet remnawave_protect"
echo

# После успешной настройки DoH — запускаем rkn_protect
if systemctl is-active --quiet dnsproxy.service 2>/dev/null; then
    run_rkn_protect
fi
