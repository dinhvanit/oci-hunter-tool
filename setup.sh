#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  setup.sh — wizard tạo file .env cho oci-hunter
#
#  Tự lấy OCID qua oci-cli: tenancy, AD, compartment, subnet (tạo VCN nếu cần),
#  image. Chỉ cần chọn bằng số, không phải copy OCID từ web console.
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

BOLD=$'\033[1m'; CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; RESET=$'\033[0m'

info()   { printf '%s[→]%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()     { printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error()  { printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*" >&2; }
header() { printf '\n%s── %s ──%s\n' "$BOLD" "$*" "$RESET"; }

ANSWER=""
ask() {
  local prompt="$1" default="${2:-}" input=""
  if [[ -r /dev/tty ]]; then
    read -r -p "    ${prompt}${default:+ [$default]}: " input </dev/tty || true
  fi
  ANSWER="${input:-$default}"
}

ask_secret() {
  local prompt="$1" input=""
  if [[ -r /dev/tty ]]; then
    read -rs -p "    ${prompt}: " input </dev/tty || true
    printf '\n'
  fi
  ANSWER="$input"
}

# -----------------------------------------------------------------------------
# Menu số: pick_menu "Câu hỏi" TÊN_BIẾN "nhãn|giá trị" ...
# -----------------------------------------------------------------------------
pick_menu() {
  local prompt="$1" result_var="$2"
  shift 2
  local -a entries=("$@")
  local count=${#entries[@]} i=0 entry choice

  for entry in "${entries[@]}"; do
    printf '  %s[%d]%s %s\n' "$CYAN" "$i" "$RESET" "${entry%%|*}"
    i=$((i + 1))
  done

  while true; do
    read -r -p "    ${prompt} [0-$((count - 1))]: " choice </dev/tty || true
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 0 && choice < count)); then
      entry="${entries[$choice]}"
      printf -v "$result_var" '%s' "${entry##*|}"
      ok "Đã chọn: ${entry%%|*}"
      return 0
    fi
    warn "Số không hợp lệ, chọn từ 0 đến $((count - 1))."
  done
}

oci_json() {
  local desc="$1"; shift
  local out
  if ! out="$("$@" 2>&1)"; then
    error "$desc"
    printf '%s\n' "$out" | head -n 12 >&2
    return 1
  fi
  printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# 0. Kiểm tra môi trường
# -----------------------------------------------------------------------------
check_prereqs() {
  header "Kiểm tra môi trường"

  local c
  for c in oci jq; do
    if ! command -v "$c" >/dev/null 2>&1; then
      error "Chưa có '$c'."
      [[ "$c" == "jq" ]] && echo "  Ubuntu/Debian: sudo apt install -y jq | Oracle Linux: sudo dnf install -y jq"
      [[ "$c" == "oci" ]] && echo "  Cài oci-cli: bash -c \"\$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\""
      exit 1
    fi
  done
  ok "oci-cli: $(oci --version 2>&1 | head -n 1)"
  ok "jq: $(jq --version)"

  if [[ ! -f "$HOME/.oci/config" ]]; then
    error "Chưa có $HOME/.oci/config — chạy 'oci setup config' trước."
    exit 1
  fi
  grep -q '^tenancy=' "$HOME/.oci/config" || {
    error "File ~/.oci/config thiếu dòng 'tenancy='."
    exit 1
  }
  ok "Đã có ~/.oci/config"

  if [[ -f "$ENV_FILE" ]]; then
    warn ".env đã tồn tại."
    ask "Ghi đè? (y/N)" "N"
    [[ "$ANSWER" =~ ^[yY]$ ]] || { echo "Đã hủy."; exit 0; }
  fi
}

# -----------------------------------------------------------------------------
# 1. Tenancy + region
# -----------------------------------------------------------------------------
get_tenancy() {
  header "1/8 — Tenancy"
  TENANCY_OCID="$(grep '^tenancy=' "$HOME/.oci/config" | head -n 1 | cut -d'=' -f2 | tr -d ' \r')"
  REGION="$(grep '^region=' "$HOME/.oci/config" | head -n 1 | cut -d'=' -f2 | tr -d ' \r' || true)"
  ok "Tenancy: ${TENANCY_OCID}"
  [[ -n "$REGION" ]] && ok "Region: ${REGION}"
}

# -----------------------------------------------------------------------------
# 2. Availability domains
# -----------------------------------------------------------------------------
get_ads() {
  header "2/8 — Availability Domains"
  local raw
  raw="$(oci_json "Không lấy được danh sách AD." \
    oci iam availability-domain list --compartment-id "$TENANCY_OCID" --all --output json)"

  AVAILABILITY_DOMAINS="$(jq -r '.data[].name' <<<"$raw" | tr '\n' ' ' | xargs)"
  [[ -n "$AVAILABILITY_DOMAINS" ]] || { error "Không có AD nào."; exit 1; }
  ok "AD: ${AVAILABILITY_DOMAINS}"
}

# -----------------------------------------------------------------------------
# 3. Compartment
# -----------------------------------------------------------------------------
get_compartment() {
  header "3/8 — Compartment"
  info "Đang liệt kê compartment..."

  local raw
  raw="$(oci_json "Không liệt kê được compartment." \
    oci iam compartment list \
      --compartment-id "$TENANCY_OCID" \
      --compartment-id-in-subtree true \
      --lifecycle-state ACTIVE \
      --all --output json)"

  local -a entries=("root (tenancy)|${TENANCY_OCID}")
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && entries+=("$line")
  done < <(jq -r '.data[] | "\(.name)|\(.id)"' <<<"$raw")

  echo ""
  pick_menu "Chọn compartment:" COMPARTMENT_OCID "${entries[@]}"
}

# -----------------------------------------------------------------------------
# 4. Shape
# -----------------------------------------------------------------------------
get_shape() {
  header "4/8 — Shape"
  local -a entries=(
    "VM.Standard.A1.Flex — ARM Ampere (Always Free, khuyến nghị)|VM.Standard.A1.Flex"
    "VM.Standard.E2.1.Micro — AMD nhỏ (Always Free)|VM.Standard.E2.1.Micro"
  )
  echo ""
  pick_menu "Chọn shape:" SHAPE "${entries[@]}"

  if [[ "$SHAPE" == *"Flex"* ]]; then
    ask "Số OCPU (Always Free tối đa 4)" "2"
    OCPUS="$ANSWER"
    ask "RAM GB (Always Free tối đa 24)" "12"
    MEMORY_GB="$ANSWER"

    [[ "$OCPUS" =~ ^[0-9]+$ ]] || { error "OCPU phải là số nguyên."; exit 1; }
    [[ "$MEMORY_GB" =~ ^[0-9]+$ ]] || { error "RAM phải là số nguyên."; exit 1; }
    if ((OCPUS > 4 || MEMORY_GB > 24)); then
      warn "Vượt hạn mức Always Free (4 OCPU / 24 GB) — có thể bị tính phí."
    fi
  else
    OCPUS="1"
    MEMORY_GB="1"
  fi

  ask "Dung lượng boot volume (GB, để trống = mặc định của image)" "50"
  BOOT_VOLUME_SIZE_GB="$ANSWER"
}

# -----------------------------------------------------------------------------
# 5. Subnet — tự tạo VCN đầy đủ nếu chưa có
# -----------------------------------------------------------------------------
create_vcn_stack() {
  info "Tạo VCN + Internet Gateway + Route Table + Security List + Subnet..."

  local raw vcn_id rt_id sl_id ig_id
  raw="$(oci_json "Tạo VCN thất bại." \
    oci network vcn create \
      --compartment-id "$COMPARTMENT_OCID" \
      --cidr-block "10.0.0.0/16" \
      --display-name "vcn-oci-hunter" \
      --dns-label "vcnocihunter" \
      --output json)"
  vcn_id="$(jq -r '.data.id' <<<"$raw")"
  rt_id="$(jq -r '.data."default-route-table-id"' <<<"$raw")"
  sl_id="$(jq -r '.data."default-security-list-id"' <<<"$raw")"
  ok "VCN: vcn-oci-hunter"

  raw="$(oci_json "Tạo Internet Gateway thất bại." \
    oci network internet-gateway create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$vcn_id" \
      --is-enabled true \
      --display-name "ig-oci-hunter" \
      --output json)"
  ig_id="$(jq -r '.data.id' <<<"$raw")"
  ok "Internet Gateway: ig-oci-hunter"

  oci_json "Cập nhật route table thất bại." \
    oci network route-table update \
      --rt-id "$rt_id" \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$ig_id\"}]" \
      --force --output json >/dev/null
  ok "Route: 0.0.0.0/0 → Internet Gateway"

  oci_json "Cập nhật security list thất bại." \
    oci network security-list update \
      --security-list-id "$sl_id" \
      --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},{"source":"0.0.0.0/0","protocol":"1","isStateless":false,"icmpOptions":{"type":3,"code":4}}]' \
      --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' \
      --force --output json >/dev/null
  ok "Security list: mở SSH 22 + ICMP + egress"

  raw="$(oci_json "Tạo subnet thất bại." \
    oci network subnet create \
      --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$vcn_id" \
      --cidr-block "10.0.0.0/24" \
      --display-name "subnet-oci-hunter" \
      --dns-label "subnetocihunter" \
      --route-table-id "$rt_id" \
      --security-list-ids "[\"$sl_id\"]" \
      --prohibit-public-ip-on-vnic false \
      --output json)"
  SUBNET_OCID="$(jq -r '.data.id' <<<"$raw")"
  ok "Subnet: subnet-oci-hunter (10.0.0.0/24)"
}

get_subnet() {
  header "5/8 — Subnet"

  local raw count
  raw="$(oci_json "Không liệt kê được VCN." \
    oci network vcn list \
      --compartment-id "$TENANCY_OCID" \
      --compartment-id-in-subtree true \
      --all --output json)"
  count="$(jq '.data | length' <<<"$raw")"

  if ((count == 0)); then
    warn "Tài khoản chưa có VCN nào."
    ask "Tạo VCN công khai mới? (Y/n)" "Y"
    if [[ "$ANSWER" =~ ^[yY] ]]; then
      create_vcn_stack
      return 0
    fi
    error "Cần subnet để tạo instance."
    exit 1
  fi

  local vcn_id
  if ((count == 1)); then
    vcn_id="$(jq -r '.data[0].id' <<<"$raw")"
    ok "VCN duy nhất: $(jq -r '.data[0]."display-name"' <<<"$raw")"
  else
    local -a vcn_entries=() line
    while IFS= read -r line; do
      [[ -n "$line" ]] && vcn_entries+=("$line")
    done < <(jq -r '.data[] | "\(."display-name") [\(."cidr-block")]|\(.id)"' <<<"$raw")
    echo ""
    pick_menu "Chọn VCN:" vcn_id "${vcn_entries[@]}"
  fi

  local vcn_compartment
  vcn_compartment="$(jq -r --arg id "$vcn_id" '.data[] | select(.id == $id) | ."compartment-id"' <<<"$raw")"

  local sub_raw sub_count
  sub_raw="$(oci_json "Không liệt kê được subnet." \
    oci network subnet list \
      --compartment-id "$vcn_compartment" \
      --vcn-id "$vcn_id" \
      --all --output json)"
  sub_count="$(jq '.data | length' <<<"$sub_raw")"

  if ((sub_count == 0)); then
    error "VCN đã chọn không có subnet. Tạo subnet trong VCN đó rồi chạy lại setup."
    exit 1
  fi

  if ((sub_count == 1)); then
    SUBNET_OCID="$(jq -r '.data[0].id' <<<"$sub_raw")"
    ok "Subnet duy nhất: $(jq -r '.data[0]."display-name"' <<<"$sub_raw")"
  else
    local -a sub_entries=() sline
    while IFS= read -r sline; do
      [[ -n "$sline" ]] && sub_entries+=("$sline")
    done < <(jq -r '.data[] | "\(."display-name") [\(."cidr-block")]|\(.id)"' <<<"$sub_raw")
    echo ""
    pick_menu "Chọn subnet:" SUBNET_OCID "${sub_entries[@]}"
  fi

  if [[ "$(jq -r --arg id "$SUBNET_OCID" '.data[] | select(.id == $id) | ."prohibit-public-ip-on-vnic"' <<<"$sub_raw")" == "true" ]]; then
    warn "Subnet này chặn public IP — instance sẽ không có IP công khai để SSH."
  fi
}

# -----------------------------------------------------------------------------
# 6. Image
# -----------------------------------------------------------------------------
get_image() {
  header "6/8 — Image (hệ điều hành)"
  info "Đang liệt kê image cho ${SHAPE}..."

  local raw
  raw="$(oci_json "Không liệt kê được image." \
    oci compute image list \
      --compartment-id "$TENANCY_OCID" \
      --shape "$SHAPE" \
      --lifecycle-state AVAILABLE \
      --sort-by TIMECREATED --sort-order DESC \
      --all --output json)"

  local -a entries=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && entries+=("$line")
  done < <(jq -r '.data[:15][] | "\(."display-name")|\(.id)"' <<<"$raw")
  entries+=("Nhập OCID image thủ công|__manual__")

  if ((${#entries[@]} == 1)); then
    error "Không có image nào cho shape ${SHAPE}."
    exit 1
  fi

  echo ""
  pick_menu "Chọn image:" IMAGE_OCID "${entries[@]}"

  if [[ "$IMAGE_OCID" == "__manual__" ]]; then
    while true; do
      ask "Dán OCID image" ""
      if [[ "$ANSWER" == ocid1.image.* ]]; then
        IMAGE_OCID="$ANSWER"
        break
      fi
      warn "OCID image phải bắt đầu bằng 'ocid1.image.'"
    done
  fi
  ok "Image: ${IMAGE_OCID}"
}

# -----------------------------------------------------------------------------
# 7. SSH key
# -----------------------------------------------------------------------------
get_ssh_key() {
  header "7/8 — SSH public key"

  local default=""
  local f
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$f" ]]; then
      default="$f"
      break
    fi
  done

  info "Có thể nhập đường dẫn file .pub hoặc dán trực tiếp nội dung key."
  while true; do
    ask "Đường dẫn / nội dung public key" "$default"
    local value="${ANSWER/#\~/$HOME}"

    if [[ -f "$value" ]]; then
      SSH_PUBLIC_KEY="$(tr -d '\n' <"$value")"
    else
      SSH_PUBLIC_KEY="$value"
    fi

    if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-|ecdsa-) ]]; then
      ok "Đã nhận public key ($(printf '%s' "$SSH_PUBLIC_KEY" | cut -d' ' -f1))."
      break
    fi
    warn "Key không hợp lệ — phải bắt đầu bằng 'ssh-ed25519', 'ssh-rsa', 'ecdsa-...'."
  done
}

# -----------------------------------------------------------------------------
# 8. Telegram + tham số vòng lặp
# -----------------------------------------------------------------------------
# Lấy chat_id từ getUpdates (nếu người dùng đã nhắn bot ít nhất 1 lần)
detect_chat_id() {
  local token="$1" raw
  [[ -n "$token" ]] || return 0
  raw="$(curl -sS --max-time 15 "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null || true)"
  jq -r '[.result[]?.message.chat.id] | last // empty' <<<"$raw" 2>/dev/null || true
}

get_telegram() {
  header "8/8 — Telegram + chu kỳ chạy"

  info "Bỏ trống nếu chưa muốn dùng Telegram. Xem README để biết cách lấy token."
  ask_secret "Bot token (Enter để bỏ qua)"
  TELEGRAM_BOT_TOKEN="$ANSWER"

  TELEGRAM_CHAT_ID=""
  if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
    local detected=""
    detected="$(detect_chat_id "$TELEGRAM_BOT_TOKEN")"
    if [[ -n "$detected" ]]; then
      info "Tự phát hiện chat_id: ${detected}"
    fi
    ask "Chat ID" "$detected"
    TELEGRAM_CHAT_ID="$ANSWER"

    if [[ -n "$TELEGRAM_CHAT_ID" ]] && command -v curl >/dev/null 2>&1; then
      ask "Gửi tin nhắn thử ngay? (Y/n)" "Y"
      if [[ "$ANSWER" =~ ^[yY] ]]; then
        if curl -sS --max-time 15 -X POST \
          --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
          --data-urlencode "text=✅ setup.sh: Telegram đã kết nối với oci-hunter" \
          "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>/dev/null | grep -q '"ok":true'; then
          ok "Đã gửi tin nhắn thử."
        else
          warn "Gửi thất bại — kiểm tra lại token/chat_id."
        fi
      fi
    fi
  fi

  echo ""
  info "Chu kỳ càng dài càng ít bị rate limit. Mặc định 300-600s (5-10 phút)."
  ask "Chu kỳ tối thiểu (giây)" "300"
  INTERVAL_MIN="$ANSWER"
  ask "Chu kỳ tối đa (giây)" "600"
  INTERVAL_MAX="$ANSWER"
  ask "Lùi khi bị rate limit (giây)" "900"
  RATE_LIMIT_BACKOFF="$ANSWER"
  ask "Lùi tối đa khi rate limit liên tục (giây)" "1800"
  RATE_LIMIT_BACKOFF_MAX="$ANSWER"
  ask "Báo cáo Telegram mỗi (phút, 0 = tắt)" "60"
  HEARTBEAT_MIN="$ANSWER"

  local v
  for v in INTERVAL_MIN INTERVAL_MAX RATE_LIMIT_BACKOFF RATE_LIMIT_BACKOFF_MAX HEARTBEAT_MIN OCPUS; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { error "$v phải là số nguyên."; exit 1; }
  done
  [[ "$MEMORY_GB" =~ ^[0-9]+$ ]] || { error "MEMORY_GB phải là số nguyên."; exit 1; }
  ((INTERVAL_MAX >= INTERVAL_MIN)) || { error "Chu kỳ tối đa phải >= tối thiểu."; exit 1; }
  ((INTERVAL_MIN >= 30)) || { error "Chu kỳ tối thiểu nên >= 30 giây để tránh rate limit."; exit 1; }
  ((RATE_LIMIT_BACKOFF >= 60)) || { error "Backoff khi rate limit nên >= 60 giây."; exit 1; }
}

# -----------------------------------------------------------------------------
# Ghi .env
# -----------------------------------------------------------------------------
write_env() {
  header "Ghi .env"

  ask "Tên instance" "arm-free"
  DISPLAY_NAME="$ANSWER"

  cat >"$ENV_FILE" <<EOF
# oci-hunter — tạo bởi setup.sh lúc $(date '+%Y-%m-%d %H:%M:%S')
# KHÔNG commit file này (chứa token Telegram).

# --- OCI ---
TENANCY_OCID="${TENANCY_OCID}"
COMPARTMENT_OCID="${COMPARTMENT_OCID}"
SUBNET_OCID="${SUBNET_OCID}"
AVAILABILITY_DOMAINS="${AVAILABILITY_DOMAINS}"
IMAGE_OCID="${IMAGE_OCID}"

# --- Instance ---
SHAPE="${SHAPE}"
OCPUS=${OCPUS}
MEMORY_GB=${MEMORY_GB}
DISPLAY_NAME="${DISPLAY_NAME}"
BOOT_VOLUME_SIZE_GB="${BOOT_VOLUME_SIZE_GB}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"

# --- Nhịp chạy (giây) ---
INTERVAL_MIN=${INTERVAL_MIN}
INTERVAL_MAX=${INTERVAL_MAX}
RATE_LIMIT_BACKOFF=${RATE_LIMIT_BACKOFF}
RATE_LIMIT_BACKOFF_MAX=${RATE_LIMIT_BACKOFF_MAX}

# --- Telegram ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
HEARTBEAT_MIN=${HEARTBEAT_MIN}

# --- Webhook dự phòng (ntfy.sh, Discord...) — bỏ trống nếu không dùng ---
NOTIFY_URL=""
EOF

  chmod 600 "$ENV_FILE"
  ok "Đã ghi $ENV_FILE (quyền 600)."
}

main() {
  printf '\n%s╔══════════════════════════════════════════╗%s\n' "$BOLD" "$RESET"
  printf '%s║        oci-hunter — cấu hình ban đầu     ║%s\n' "$BOLD" "$RESET"
  printf '%s╚══════════════════════════════════════════╝%s\n' "$BOLD" "$RESET"

  check_prereqs
  get_tenancy
  get_ads
  get_compartment
  get_shape
  get_subnet
  get_image
  get_ssh_key
  get_telegram
  write_env

  printf '\n%sCấu hình xong!%s\n\n' "$GREEN$BOLD" "$RESET"
  cat <<'EOF'
  Bước tiếp theo:
    make doctor     # kiểm tra lại toàn bộ cấu hình + gửi thử Telegram
    make run        # chạy trực tiếp (Ctrl+C để dừng)
    make run-bg     # chạy nền trong tmux
    make install    # cài systemd, tự chạy lại khi reboot
    make logs       # theo dõi log
EOF
  echo ""
}

main "$@"
