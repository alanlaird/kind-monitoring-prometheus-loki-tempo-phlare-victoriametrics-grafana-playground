#!/bin/bash
# ============================================================
# metallb-dnat.sh
# Dynamically discovers all Kubernetes LoadBalancer services
# via `kubectl get svc --all-namespaces` and maintains
# iptables DNAT rules so they are reachable from the LAN.
#
# Usage:
#   sudo ./metallb-dnat.sh [apply|remove|status|list|watch|install]
#
# Edit the CONFIG section below if needed.
# ============================================================

set -euo pipefail

# ─── CONFIG ─────────────────────────────────────────────────
# Path to kubectl (auto-detected if empty)
KUBECTL=""

# Kubeconfig to use (leave empty for default ~/.kube/config)
KUBECONFIG_PATH=""

# Only consider services in these namespaces (space-separated).
# Leave empty to include ALL namespaces.
NAMESPACES=""

# Only include services whose EXTERNAL-IP matches this prefix.
# Useful to scope to the MetalLB subnet (e.g. "172.18.255.")
# Leave empty to include all assigned external IPs.
METALLB_IP_PREFIX=""

# Network interface facing your LAN. Auto-detected if empty.
LAN_IFACE=""

# Optional: restrict DNAT to traffic from a specific source subnet.
ALLOWED_SRC=""   # e.g. "192.168.1.0/24"

# Rule tag used to identify rules managed by this script.
RULE_TAG="metallb-dnat"

# How often (seconds) watch mode re-checks rules.
WATCH_INTERVAL=30
# ────────────────────────────────────────────────────────────

# ─── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Pre-flight ─────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || { error "Run as root (sudo)."; exit 1; }
}

resolve_kubectl() {
  if [[ -z "$KUBECTL" ]]; then
    KUBECTL=$(command -v kubectl 2>/dev/null || true)
    [[ -n "$KUBECTL" ]] || { error "kubectl not found. Install it or set KUBECTL in CONFIG."; exit 1; }
  fi
  [[ -n "$KUBECONFIG_PATH" ]] && export KUBECONFIG="$KUBECONFIG_PATH"
}

detect_iface() {
  if [[ -z "$LAN_IFACE" ]]; then
    LAN_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
    [[ -n "$LAN_IFACE" ]] || { error "Cannot auto-detect LAN interface. Set LAN_IFACE in CONFIG."; exit 1; }
    info "Auto-detected LAN interface: ${BOLD}${LAN_IFACE}${NC}"
  fi
}

get_host_lan_ip() {
  ip -4 addr show "$LAN_IFACE" | awk '/inet / {split($2,a,"/"); print a[1]; exit}'
}

# ─── kubectl discovery ──────────────────────────────────────
# Prints one line per LoadBalancer service that has an assigned
# external IP. Each line is:  NAMESPACE  SVC_NAME  EXTERNAL_IP  PORT_PAIRS
# PORT_PAIRS is comma-separated HOST_PORT:SVC_PORT (same port both sides).
#
# Example:
#   default nginx-lb 172.18.255.200 80:80,443:443
discover_services() {
  resolve_kubectl

  local raw
  if [[ -n "$NAMESPACES" ]]; then
    raw=""
    for ns in $NAMESPACES; do
      raw+=$("$KUBECTL" get svc -n "$ns" \
        --no-headers \
        -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.status.loadBalancer.ingress[0].ip,PORTS:.spec.ports[*].port' \
        2>/dev/null || true)
      raw+=$'\n'
    done
  else
    raw=$("$KUBECTL" get svc --all-namespaces \
      --no-headers \
      -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTIP:.status.loadBalancer.ingress[0].ip,PORTS:.spec.ports[*].port' \
      2>/dev/null || true)
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local ns name stype extip ports_raw
    read -r ns name stype extip ports_raw <<< "$line"

    [[ "$stype" != "LoadBalancer" ]]                           && continue
    [[ -z "$extip" || "$extip" == "<none>" || "$extip" == "none" ]] && continue

    if [[ -n "$METALLB_IP_PREFIX" ]]; then
      [[ "$extip" == ${METALLB_IP_PREFIX}* ]] || continue
    fi

    # Build comma-separated port pairs
    local port_pairs=""
    IFS=',' read -r -a port_arr <<< "$ports_raw"
    for p in "${port_arr[@]}"; do
      p="${p// /}"
      [[ -z "$p" || "$p" == "<none>" ]] && continue
      port_pairs+="${p}:${p},"
    done
    port_pairs="${port_pairs%,}"

    [[ -z "$port_pairs" ]] && continue
    echo "$ns $name $extip $port_pairs"

  done <<< "$raw"
}

# ─── iptables helpers ────────────────────────────────────────
_rule_exists_prerouting() {
  local host_port=$1 dest_ip=$2 dest_port=$3
  iptables -t nat -C PREROUTING \
    -i "$LAN_IFACE" -p tcp --dport "$host_port" \
    -m comment --comment "${RULE_TAG}" \
    -j DNAT --to-destination "${dest_ip}:${dest_port}" \
    2>/dev/null
}

_docker_user_chain_exists() {
  iptables -L DOCKER-USER -n &>/dev/null
}

_rule_exists_forward() {
  local dest_ip=$1 dest_port=$2
  # Prefer DOCKER-USER (runs before Docker's DROP rules); fall back to FORWARD
  if _docker_user_chain_exists; then
    iptables -C DOCKER-USER \
      -p tcp -d "$dest_ip" --dport "$dest_port" \
      -m comment --comment "${RULE_TAG}" \
      -j ACCEPT \
      2>/dev/null
  else
    iptables -C FORWARD \
      -p tcp -d "$dest_ip" --dport "$dest_port" \
      -m comment --comment "${RULE_TAG}" \
      -j ACCEPT \
      2>/dev/null
  fi
}

_rule_exists_masquerade() {
  local dest_ip=$1
  iptables -t nat -C POSTROUTING \
    -d "$dest_ip" \
    -m comment --comment "${RULE_TAG}" \
    -j MASQUERADE \
    2>/dev/null
}

ensure_ip_forward() {
  if [[ $(cat /proc/sys/net/ipv4/ip_forward) -ne 1 ]]; then
    info "Enabling ip_forward..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
      echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
      info "Persisted ip_forward in /etc/sysctl.conf"
    fi
  fi
}

# Apply rules for one service (args: ns svc extip port_pairs)
apply_service_rules() {
  local ns=$1 svc=$2 extip=$3 port_pairs=$4
  local src_opt=""
  [[ -n "$ALLOWED_SRC" ]] && src_opt="-s ${ALLOWED_SRC}"

  if ! _rule_exists_masquerade "$extip"; then
    iptables -t nat -A POSTROUTING \
      -d "$extip" \
      -m comment --comment "${RULE_TAG}" \
      -j MASQUERADE
    success "  MASQUERADE  → ${extip}"
  fi

  IFS=',' read -r -a pairs <<< "$port_pairs"
  for pair in "${pairs[@]}"; do
    local host_port="${pair%%:*}"
    local svc_port="${pair##*:}"

    if ! _rule_exists_prerouting "$host_port" "$extip" "$svc_port"; then
      # shellcheck disable=SC2086
      iptables -t nat -A PREROUTING \
        -i "$LAN_IFACE" -p tcp --dport "$host_port" \
        $src_opt \
        -m comment --comment "${RULE_TAG}" \
        -j DNAT --to-destination "${extip}:${svc_port}"
      success "  DNAT    :${host_port} → ${extip}:${svc_port}"
    else
      warn "  DNAT    :${host_port} → ${extip}:${svc_port}  (already exists)"
    fi

    if ! _rule_exists_forward "$extip" "$svc_port"; then
      # Insert at position 1 so our ACCEPT runs before Docker's DROP rules.
      # DOCKER-USER is the correct chain — Docker guarantees it is always
      # consulted before its own isolation/drop rules.
      if _docker_user_chain_exists; then
        iptables -I DOCKER-USER 1 \
          -p tcp -d "$extip" --dport "$svc_port" \
          -m comment --comment "${RULE_TAG}" \
          -j ACCEPT
        success "  DOCKER-USER → ${extip}:${svc_port}  (inserted at position 1)"
      else
        iptables -I FORWARD 1 \
          -p tcp -d "$extip" --dport "$svc_port" \
          -m comment --comment "${RULE_TAG}" \
          -j ACCEPT
        success "  FORWARD → ${extip}:${svc_port}  (inserted at position 1)"
      fi
    else
      warn "  FORWARD → ${extip}:${svc_port}  (already exists)"
    fi
  done
}

# ─── apply ───────────────────────────────────────────────────
apply_rules() {
  require_root
  detect_iface
  ensure_ip_forward

  local host_ip
  host_ip=$(get_host_lan_ip)

  info "Discovering LoadBalancer services via kubectl..."
  local services
  services=$(discover_services)

  if [[ -z "$services" ]]; then
    warn "No LoadBalancer services with assigned external IPs found."
    warn "Try: kubectl get svc --all-namespaces"
    return 0
  fi

  echo ""
  printf "  %-20s %-30s %-18s %s\n" "NAMESPACE" "SERVICE" "EXTERNAL-IP" "PORTS"
  printf "  %-20s %-30s %-18s %s\n" "──────────────────" "────────────────────────────" "────────────────" "──────────"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r ns svc extip ports <<< "$line"
    printf "  %-20s %-30s %-18s %s\n" "$ns" "$svc" "$extip" "${ports//,/  }"
  done <<< "$services"
  echo ""

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r ns svc extip port_pairs <<< "$line"
    info "[${ns}/${svc}]  ${extip}"
    apply_service_rules "$ns" "$svc" "$extip" "$port_pairs"
  done <<< "$services"

  echo ""
  success "Rules applied. Access services from ${BOLD}${host_ip}${NC}:"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r ns svc extip port_pairs <<< "$line"
    IFS=',' read -r -a pairs <<< "$port_pairs"
    for pair in "${pairs[@]}"; do
      local hp="${pair%%:*}"
      echo -e "  ${BOLD}http://${host_ip}:${hp}${NC}  →  ${ns}/${svc}  (${extip}:${hp})"
    done
  done <<< "$services"
}

# ─── remove ──────────────────────────────────────────────────
remove_rules() {
  require_root
  info "Removing all iptables rules tagged '${RULE_TAG}'..."
  local removed=0

  while iptables-save | grep -q "comment.*${RULE_TAG}"; do
    while IFS= read -r args; do
      iptables -t nat -D PREROUTING $args 2>/dev/null && ((removed++)) || true
    done < <(iptables -t nat -S PREROUTING | grep "comment.*${RULE_TAG}" | sed 's/^-A PREROUTING //')

    while IFS= read -r args; do
      iptables -t nat -D POSTROUTING $args 2>/dev/null && ((removed++)) || true
    done < <(iptables -t nat -S POSTROUTING | grep "comment.*${RULE_TAG}" | sed 's/^-A POSTROUTING //')

    while IFS= read -r args; do
      iptables -D FORWARD $args 2>/dev/null && ((removed++)) || true
    done < <(iptables -S FORWARD | grep "comment.*${RULE_TAG}" | sed 's/^-A FORWARD //')

    # Also clean DOCKER-USER if it exists
    if _docker_user_chain_exists; then
      while IFS= read -r args; do
        iptables -D DOCKER-USER $args 2>/dev/null && ((removed++)) || true
      done < <(iptables -S DOCKER-USER | grep "comment.*${RULE_TAG}" | sed 's/^-A DOCKER-USER //')
    fi
  done

  if [[ $removed -gt 0 ]]; then
    success "Removed ${removed} rule(s)."
  else
    warn "No rules with tag '${RULE_TAG}' found."
  fi
}

# ─── list ────────────────────────────────────────────────────
list_services() {
  resolve_kubectl
  info "Querying kubectl for LoadBalancer services...\n"
  local services
  services=$(discover_services)

  if [[ -z "$services" ]]; then
    warn "No LoadBalancer services with assigned external IPs found."
    return 0
  fi

  printf "  %-20s %-30s %-18s %s\n" "NAMESPACE" "SERVICE" "EXTERNAL-IP" "PORTS"
  printf "  %-20s %-30s %-18s %s\n" "──────────────────" "────────────────────────────" "────────────────" "──────────"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r ns svc extip ports <<< "$line"
    printf "  %-20s %-30s %-18s %s\n" "$ns" "$svc" "$extip" "${ports//,/  }"
  done <<< "$services"
  echo ""
}

# ─── status ──────────────────────────────────────────────────
show_status() {
  require_root
  detect_iface

  echo -e "\n${BOLD}=== MetalLB DNAT Status ===${NC}"
  echo -e "Interface  : ${CYAN}${LAN_IFACE}${NC}"
  echo -e "Host LAN IP: ${CYAN}$(get_host_lan_ip)${NC}\n"

  echo -e "${BOLD}Discovered LoadBalancer services:${NC}"
  list_services || true

  echo -e "${BOLD}ip_forward:${NC} $(cat /proc/sys/net/ipv4/ip_forward)\n"

  echo -e "${BOLD}NAT rules managed by this script:${NC}"
  local nat_rules
  nat_rules=$(iptables -t nat -S | grep "comment.*${RULE_TAG}" || true)
  if [[ -n "$nat_rules" ]]; then
    echo "$nat_rules" | while IFS= read -r r; do echo "  $r"; done
  else
    warn "  None found."
  fi

  echo -e "\n${BOLD}FORWARD/DOCKER-USER rules managed by this script:${NC}"
  local fwd_rules
  fwd_rules=$(  { iptables -S FORWARD 2>/dev/null; _docker_user_chain_exists && iptables -S DOCKER-USER 2>/dev/null || true; } \
    | grep "comment.*${RULE_TAG}" || true)
  if [[ -n "$fwd_rules" ]]; then
    echo "$fwd_rules" | while IFS= read -r r; do echo "  $r"; done
  else
    warn "  None found."
  fi
  echo ""
}

# ─── watch ───────────────────────────────────────────────────
watch_and_repair() {
  require_root
  detect_iface

  info "Watch mode: re-syncing every ${WATCH_INTERVAL}s. New/removed services detected automatically."
  info "Press Ctrl+C to stop.\n"

  while true; do
    local services
    services=$(discover_services 2>/dev/null || true)

    if [[ -z "$services" ]]; then
      warn "$(date '+%H:%M:%S') — No LoadBalancer services found. Waiting..."
      sleep "$WATCH_INTERVAL"
      continue
    fi

    local missing=0

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      read -r ns svc extip port_pairs <<< "$line"

      if ! _rule_exists_masquerade "$extip"; then
        warn "MASQUERADE missing for ${extip} (${ns}/${svc})"
        missing=1
      fi

      IFS=',' read -r -a pairs <<< "$port_pairs"
      for pair in "${pairs[@]}"; do
        local hp="${pair%%:*}" sp="${pair##*:}"
        if ! _rule_exists_prerouting "$hp" "$extip" "$sp"; then
          warn "DNAT missing    :${hp} → ${extip}:${sp}  (${ns}/${svc})"
          missing=1
        fi
        if ! _rule_exists_forward "$extip" "$sp"; then
          local chain="DOCKER-USER"; _docker_user_chain_exists || chain="FORWARD"
          warn "${chain} missing → ${extip}:${sp}  (${ns}/${svc})"
          missing=1
        fi
      done
    done <<< "$services"

    if [[ $missing -eq 1 ]]; then
      info "Re-applying missing rules..."
      apply_rules
    else
      local count
      count=$(echo "$services" | grep -c .) || count=0
      success "$(date '+%H:%M:%S') — All rules intact (${count} service(s))."
    fi

    sleep "$WATCH_INTERVAL"
  done
}

# ─── install systemd service ─────────────────────────────────
install_systemd_service() {
  require_root
  local script_path
  script_path=$(realpath "$0")
  local svc_file="/etc/systemd/system/metallb-dnat.service"

  cat > "$svc_file" <<EOF
[Unit]
Description=MetalLB DNAT iptables maintenance
After=network.target docker.service

[Service]
Type=simple
ExecStart=${script_path} watch
ExecStop=${script_path} remove
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable metallb-dnat.service
  systemctl start metallb-dnat.service
  success "Installed and started metallb-dnat.service"
  info "Manage with: systemctl [status|stop|restart] metallb-dnat"
}

# ─── Entry point ─────────────────────────────────────────────
case "${1:-apply}" in
  apply)   apply_rules ;;
  remove)  remove_rules ;;
  list)    list_services ;;
  status)  show_status ;;
  watch)   watch_and_repair ;;
  install) install_systemd_service ;;
  *)
    echo -e "\nUsage: sudo $0 [command]\n"
    echo "  apply    — Discover services via kubectl and apply DNAT rules (default)"
    echo "  remove   — Remove all DNAT rules managed by this script"
    echo "  list     — Show LoadBalancer services discovered via kubectl"
    echo "  status   — Show discovered services + current iptables rules"
    echo "  watch    — Monitor every ${WATCH_INTERVAL}s, auto-repair + pick up new services"
    echo "  install  — Install as a systemd service (survives reboots)"
    echo ""
    exit 1
    ;;
esac
