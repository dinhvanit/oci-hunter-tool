#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  oci-hunter — vòng lặp săn instance OCI Always Free (ARM Ampere A1 / A1.Flex)
#
#  Tối giản: gọi `oci compute instance launch` theo chu kỳ, ghi log ra file,
#  báo Telegram khi thành công + báo cáo định kỳ, tự lùi khi bị rate limit.
#
#  Dùng: ./hunter.sh [--check|--telegram-test|--help]
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# oci-cli cài bằng install script nằm ở ~/bin hoặc ~/lib/oracle-cli/bin.
# Chỉ thêm vào PATH khi chưa tìm thấy oci (systemd có PATH rất tối giản).
if ! command -v oci >/dev/null 2>&1; then
  export PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:$PATH"
fi

# oci-cli 3.9x in cảnh báo "append OCI_API_KEY" ra stdout trước JSON khi chưa
# thêm nhãn vào key file — tắt cảnh báo và luôn lọc lấy phần JSON.
export SUPPRESS_LABEL_WARNING=True

ENV_FILE="$ROOT_DIR/.env"
LOG_FILE="$ROOT_DIR/hunter.log"
STATE_FILE="$ROOT_DIR/.hunter-state"
KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/oci-hunter-key.XXXXXX")"
MAX_LOG_BYTES=$((5 * 1024 * 1024))

# Trạng thái dùng cho báo cáo Telegram và file .hunter-state
ATTEMPT=0
AD_INDEX=0
LAST_AD=""
LAST_RESULT=""
START_EPOCH=0
LAST_HEARTBEAT=0
LAST_THROTTLE_NOTIFY=0
THROTTLE_BACKOFF=0

if [[ -t 1 ]]; then
  C_INFO=$'\033[0;36m'
  C_OK=$'\033[0;32m'
  C_WARN=$'\033[1;33m'
  C_ERR=$'\033[0;31m'
  C_OFF=$'\033[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Logging: ghi file dạng thuần (không màu) + in ra stdout (journald/tmux)
# -----------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local line color
  line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  printf '%s\n' "$line" >>"$LOG_FILE"

  case "$level" in
    INFO)  color="$C_INFO"  ;;
    OK)    color="$C_OK"    ;;
    WARN)  color="$C_WARN"  ;;
    ERROR) color="$C_ERR"   ;;
    *)     color=""         ;;
  esac
  printf '%s%s%s\n' "$color" "$line" "$C_OFF"
}

# In chi tiết phản hồi của oci-cli (giới hạn 20 dòng) để log không bị loãng
log_detail() {
  local text="$1" line
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    printf '    %s\n' "$line" >>"$LOG_FILE"
    printf '    %s\n' "$line"
  done < <(printf '%s\n' "$text" | head -n 20)
}

die() {
  log ERROR "$*"
  exit 1
}

# Chỉ giữ phần JSON trong output của oci-cli (bỏ dòng cảnh báo phía trước)
json_only() {
  sed -n '/^{/,$p' <<<"$1"
}

# -----------------------------------------------------------------------------
# Nạp cấu hình
# -----------------------------------------------------------------------------
load_env() {
  [[ -f "$ENV_FILE" ]] || {
    echo "Không thấy $ENV_FILE — chạy 'make setup' trước." >&2
    exit 1
  }

  # shellcheck source=/dev/null
  source <(tr -d '\r' <"$ENV_FILE")

  local var
  local -a missing=()
  for var in TENANCY_OCID COMPARTMENT_OCID SUBNET_OCID AVAILABILITY_DOMAINS \
             IMAGE_OCID SHAPE OCPUS MEMORY_GB DISPLAY_NAME SSH_PUBLIC_KEY; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if ((${#missing[@]} > 0)); then
    die "Thiếu biến trong .env: ${missing[*]}"
  fi

  # Chu kỳ dài mặc định để tránh rate limit của OCI
  INTERVAL_MIN="${INTERVAL_MIN:-300}"
  INTERVAL_MAX="${INTERVAL_MAX:-600}"
  RATE_LIMIT_BACKOFF="${RATE_LIMIT_BACKOFF:-900}"
  RATE_LIMIT_BACKOFF_MAX="${RATE_LIMIT_BACKOFF_MAX:-1800}"
  HEARTBEAT_MIN="${HEARTBEAT_MIN:-60}"

  for var in INTERVAL_MIN INTERVAL_MAX RATE_LIMIT_BACKOFF RATE_LIMIT_BACKOFF_MAX HEARTBEAT_MIN; do
    [[ "${!var}" =~ ^[0-9]+$ ]] || die "$var phải là số nguyên (đang là: ${!var})"
  done
  ((INTERVAL_MAX >= INTERVAL_MIN)) || die "INTERVAL_MAX phải >= INTERVAL_MIN"
  ((RATE_LIMIT_BACKOFF_MAX >= RATE_LIMIT_BACKOFF)) || die "RATE_LIMIT_BACKOFF_MAX phải >= RATE_LIMIT_BACKOFF"

  if [[ -f "$ENV_FILE" ]] && [[ "$(stat -c %a "$ENV_FILE" 2>/dev/null || echo 600)" != "600" ]]; then
    log WARN ".env chưa đặt quyền 600 (chứa token Telegram) — nên chạy: chmod 600 $ENV_FILE"
  fi
}

check_deps() {
  local c
  local -a missing=()
  for c in oci jq; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    die "Thiếu lệnh: ${missing[*]}. Cài đặt rồi chạy lại (xem README)."
  fi
  if tg_ready && ! command -v curl >/dev/null 2>&1; then
    log WARN "Không có curl — tạm tắt thông báo Telegram."
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
  fi
}

prepare_key() {
  printf '%s\n' "$SSH_PUBLIC_KEY" >"$KEY_FILE"
  chmod 600 "$KEY_FILE"
}

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
  if ((size > MAX_LOG_BYTES)); then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

# -----------------------------------------------------------------------------
# Telegram / webhook
# -----------------------------------------------------------------------------
tg_ready() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

tg_send() {
  local text="$1"
  local notify_flag="${2:-true}" # true = có âm thanh, false = im lặng
  tg_ready || return 0

  local resp
  resp="$(curl -sS --max-time 20 -X POST \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" \
    -d "disable_notification=${notify_flag}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 2>&1)" || true

  if [[ "$resp" != *'"ok":true'* ]]; then
    log WARN "Telegram không gửi được: $(printf '%s' "$resp" | tr -d '\n' | cut -c1-200)"
  fi
}

notify() {
  local text="$1"
  local mode="${2:-loud}"
  local notify_flag="true"
  [[ "$mode" == "silent" ]] && notify_flag="false"

  if tg_ready; then
    tg_send "$text" "$notify_flag"
  elif [[ -n "${NOTIFY_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
    # Webhook dạng raw text (ntfy.sh, Gotify...): bỏ thẻ HTML cho dễ đọc
    local plain
    plain="$(printf '%s' "$text" | sed -e 's/<[^>]*>//g')"
    curl -fsS --max-time 15 -H "Title: oci-hunter" --data-binary "$plain" "$NOTIFY_URL" >/dev/null 2>&1 || true
  fi
}

fmt_duration() {
  local s="${1:-0}"
  ((s < 0)) && s=0
  printf '%dd %02dh%02dm' $((s / 86400)) $(((s % 86400) / 3600)) $(((s % 3600) / 60))
}

status_text() {
  local uptime=$(( $(date +%s) - START_EPOCH ))
  cat <<EOF
<b>🪶 oci-hunter — báo cáo định kỳ</b>
Máy: <code>$(hostname)</code>
Đã chạy: $(fmt_duration "$uptime")
Số lần thử: <b>${ATTEMPT}</b>
AD gần nhất: <code>${LAST_AD:-—}</code>
Kết quả gần nhất: <code>${LAST_RESULT:-—}</code>
Chu kỳ: ${INTERVAL_MIN}-${INTERVAL_MAX}s
EOF
}

write_state() {
  local result="$1"
  cat >"$STATE_FILE" <<EOF
started_at=$STARTED_AT
updated_at=$(date '+%Y-%m-%d %H:%M:%S')
attempts=$ATTEMPT
last_result=$result
last_ad=$LAST_AD
pid=$$
host=$(hostname)
EOF
}

# -----------------------------------------------------------------------------
# Gọi OCI
# -----------------------------------------------------------------------------
launch_instance() {
  local ad="$1"
  local -a cmd=(
    oci compute instance launch
    --compartment-id "$COMPARTMENT_OCID"
    --availability-domain "$ad"
    --display-name "$DISPLAY_NAME"
    --image-id "$IMAGE_OCID"
    --shape "$SHAPE"
    --subnet-id "$SUBNET_OCID"
    --assign-public-ip true
    --ssh-authorized-keys-file "$KEY_FILE"
  )

  # Chỉ shape Flex mới có --shape-config
  if [[ "$SHAPE" == *"Flex"* ]]; then
    cmd+=(--shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}")
  fi

  if [[ -n "${BOOT_VOLUME_SIZE_GB:-}" ]]; then
    cmd+=(--boot-volume-size-in-gbs "$BOOT_VOLUME_SIZE_GB")
  fi

  "${cmd[@]}" 2>&1
}

is_success() {
  local response="$1" state
  state="$(json_only "$response" | jq -r '.data."lifecycle-state" // .data.lifecycleState // empty' 2>/dev/null || true)"
  [[ "$state" == "PROVISIONING" || "$state" == "RUNNING" || "$state" == "STARTING" ]]
}

classify() {
  local response="$1"
  if grep -qiE 'Out of host capacity|Out of capacity|InsufficientServiceCapacity' <<<"$response"; then
    printf 'capacity'
  elif grep -qiE 'TooManyRequests|LimitExceeded|Too many requests' <<<"$response"; then
    printf 'throttle'
  elif grep -qiE 'NotAuthenticated|NotAuthorized|InvalidParameter|Forbidden|CannotParseRequest|Not found' <<<"$response"; then
    printf 'fatal'
  elif grep -qiE 'RequestException|ServiceUnavailable|InternalError|timed out|timeout|Connection' <<<"$response"; then
    printf 'network'
  else
    printf 'unknown'
  fi
}

resolve_public_ip() {
  local instance_id="$1" ip="" raw="" i
  if [[ "$instance_id" != ocid1.instance.* ]]; then
    printf 'chưa rõ'
    return 0
  fi
  for ((i = 0; i < 12; i++)); do
    raw="$(oci compute instance list-vnics \
      --instance-id "$instance_id" --output json 2>&1 || true)"
    ip="$(json_only "$raw" | jq -r '.data[0]."public-ip" // empty' 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
    sleep 10
  done
  printf 'chưa gán'
}

handle_success() {
  local response="$1" ad_short="$2"
  local instance_id public_ip

  instance_id="$(json_only "$response" | jq -r '.data.id // empty' 2>/dev/null || true)"
  if [[ -z "$instance_id" ]]; then
    instance_id="$(grep -o '"id": *"ocid1\.instance[^"]*"' <<<"$response" | head -n 1 | sed -E 's/.*"(ocid1\.instance[^"]*)"/\1/' || true)"
  fi
  [[ -n "$instance_id" ]] || instance_id="không xác định"

  log OK "SĂN ĐƯỢC INSTANCE! 🎉"
  log OK "  Instance: $instance_id"
  log OK "  AD:       $ad_short"
  log INFO "Đang chờ public IP (tối đa 2 phút)..."
  public_ip="$(resolve_public_ip "$instance_id")"

  log OK "  IP:       $public_ip"
  if [[ "$public_ip" != "chưa gán" && "$public_ip" != "chưa rõ" ]]; then
    log OK "  SSH:      ssh ubuntu@${public_ip}"
  fi

  LAST_RESULT="success"
  write_state success

  notify "<b>🎉 Săn được OCI ARM!</b>
AD: <code>${ad_short}</code>
Instance: <code>${instance_id}</code>
IP: <code>${public_ip}</code>
SSH: <code>ssh ubuntu@${public_ip}</code>
Lần thử: ${ATTEMPT}" loud

  exit 0
}

# -----------------------------------------------------------------------------
# Chờ / báo cáo
# -----------------------------------------------------------------------------
random_interval() {
  local min="$INTERVAL_MIN" max="$INTERVAL_MAX"
  printf '%s' $((min + RANDOM % (max - min + 1)))
}

next_backoff() {
  local b="${THROTTLE_BACKOFF:-0}"
  if ((b == 0)); then
    b="$RATE_LIMIT_BACKOFF"
  else
    b=$((b * 2))
  fi
  ((b > RATE_LIMIT_BACKOFF_MAX)) && b="$RATE_LIMIT_BACKOFF_MAX"
  printf '%s' "$b"
}

maybe_heartbeat() {
  ((HEARTBEAT_MIN > 0)) || return 0
  local now
  now="$(date +%s)"
  ((now - LAST_HEARTBEAT >= HEARTBEAT_MIN * 60)) || return 0
  LAST_HEARTBEAT="$now"
  notify "$(status_text)" silent
}

# -----------------------------------------------------------------------------
# Chế độ chẩn đoán
# -----------------------------------------------------------------------------
doctor() {
  load_env
  check_deps
  prepare_key

  log INFO "Kiểm tra oci-cli và quyền truy cập..."
  local out region

  out="$(oci iam availability-domain list --compartment-id "$TENANCY_OCID" --output json 2>&1)" \
    || { log ERROR "Không gọi được OCI API:"; log_detail "$out"; exit 1; }
  out="$(json_only "$out")"

  local -a found=()
  mapfile -t found < <(jq -r '.data[].name' <<<"$out")
  log OK "Kết nối OCI OK — ${#found[@]} availability domain."

  local ad found_ad ok_ad
  for ad in $AVAILABILITY_DOMAINS; do
    ok_ad=0
    for found_ad in "${found[@]}"; do
      [[ "$ad" == "$found_ad" ]] && ok_ad=1
    done
    if ((ok_ad == 1)); then
      log OK "AD hợp lệ: ${ad}"
    else
      log WARN "AD không có trong tenancy: ${ad}"
    fi
  done

  out="$(oci compute image get --image-id "$IMAGE_OCID" --output json 2>&1)" \
    || { log ERROR "Không đọc được image:"; log_detail "$out"; exit 1; }
  out="$(json_only "$out")"
  log OK "Image: $(jq -r '.data."display-name"' <<<"$out") ($(jq -r '.data."operating-system"' <<<"$out"))"

  out="$(oci network subnet get --subnet-id "$SUBNET_OCID" --output json 2>&1)" \
    || { log ERROR "Không đọc được subnet:"; log_detail "$out"; exit 1; }
  out="$(json_only "$out")"
  log OK "Subnet: $(jq -r '.data."display-name"' <<<"$out") ($(jq -r '.data."cidr-block"' <<<"$out"))"

  out="$(oci compute image list --compartment-id "$TENANCY_OCID" --shape "$SHAPE" --limit 1 --output json 2>&1)" || true
  out="$(json_only "$out")"
  region="$(jq -r '.data[0].region // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$region" ]] && log OK "Region: $region"

  if command -v ssh-keygen >/dev/null 2>&1; then
    if ssh-keygen -lf "$KEY_FILE" >/dev/null 2>&1; then
      log OK "SSH public key hợp lệ."
    else
      log WARN "SSH public key có vẻ không hợp lệ — kiểm tra lại SSH_PUBLIC_KEY."
    fi
  fi

  if tg_ready; then
    tg_send "✅ <b>oci-hunter</b>: cấu hình hợp lệ trên <code>$(hostname)</code>" "false"
    log OK "Đã gửi tin nhắn thử tới Telegram."
  else
    log INFO "Chưa cấu hình Telegram (bỏ qua bước gửi thử)."
  fi

  log OK "Chẩn đoán hoàn tất."
}

telegram_test() {
  load_env
  check_deps
  if ! tg_ready && [[ -z "${NOTIFY_URL:-}" ]]; then
    die "Chưa cấu hình TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID trong .env"
  fi
  notify "✅ <b>oci-hunter</b>: tin nhắn thử từ <code>$(hostname)</code> lúc $(date '+%H:%M:%S %d/%m/%Y')" loud
  log OK "Đã gửi tin nhắn thử. Nếu không thấy, kiểm tra token/chat_id."
}

usage() {
  cat <<'EOF'
oci-hunter — săn instance OCI Always Free

  ./hunter.sh                 chạy vòng lặp săn
  ./hunter.sh --check         kiểm tra .env, OCI API, image, subnet, Telegram
  ./hunter.sh --telegram-test gửi tin nhắn thử tới Telegram
  ./hunter.sh --help          trợ giúp

Thường dùng qua Makefile: make setup | make run | make logs | make status
EOF
}

# -----------------------------------------------------------------------------
# Vòng lặp chính
# -----------------------------------------------------------------------------
main() {
  load_env
  check_deps
  rotate_log
  prepare_key

  local -a AD_LIST=()
  read -ra AD_LIST <<<"$AVAILABILITY_DOMAINS"
  local ad_count=${#AD_LIST[@]}
  ((ad_count > 0)) || die "AVAILABILITY_DOMAINS rỗng."

  START_EPOCH="$(date +%s)"
  STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
  LAST_HEARTBEAT="$START_EPOCH"

  log INFO "oci-hunter khởi động (PID $$)"
  log INFO "Shape: ${SHAPE} — ${OCPUS} OCPU / ${MEMORY_GB} GB — tên: ${DISPLAY_NAME}"
  log INFO "AD: ${AD_LIST[*]}"
  log INFO "Chu kỳ: ${INTERVAL_MIN}-${INTERVAL_MAX}s | rate limit: lùi ${RATE_LIMIT_BACKOFF}s → ${RATE_LIMIT_BACKOFF_MAX}s"
  log INFO "Log: ${LOG_FILE}"

  notify "<b>🪶 oci-hunter đã khởi động</b>
Máy: <code>$(hostname)</code>
Shape: <code>${SHAPE}</code> — ${OCPUS} OCPU / ${MEMORY_GB} GB
Chu kỳ: ${INTERVAL_MIN}-${INTERVAL_MAX}s" silent

  while true; do
    ATTEMPT=$((ATTEMPT + 1))
    local ad="${AD_LIST[$AD_INDEX]}"
    local ad_short="${ad##*:}"
    LAST_AD="$ad_short"

    log INFO "Lần thử #${ATTEMPT} — AD: ${ad_short}"

    local response
    response="$(launch_instance "$ad")" || true

    if is_success "$response"; then
      handle_success "$response" "$ad_short"
    fi

    local result sleep_for
    result="$(classify "$response")"
    LAST_RESULT="$result"

    case "$result" in
      capacity)
        THROTTLE_BACKOFF=0
        log WARN "Hết capacity ở ${ad_short} — xoay AD."
        sleep_for="$(random_interval)"
        ;;
      throttle)
        THROTTLE_BACKOFF="$(next_backoff)"
        log WARN "Dính rate limit — lùi ${THROTTLE_BACKOFF}s để không bị khóa thêm."
        if (($(date +%s) - LAST_THROTTLE_NOTIFY >= 1800)); then
          LAST_THROTTLE_NOTIFY="$(date +%s)"
          notify "⚠️ <b>oci-hunter</b> bị rate limit trên <code>$(hostname)</code>.
Đang lùi ${THROTTLE_BACKOFF}s. Tổng số lần thử: ${ATTEMPT}." silent
        fi
        local jitter=$((THROTTLE_BACKOFF / 10))
        ((jitter < 1)) && jitter=1
        sleep_for=$((THROTTLE_BACKOFF + RANDOM % (jitter + 1)))
        ;;
      fatal)
        log ERROR "Lỗi xác thực / tham số — dừng để tránh gọi API vô ích."
        log_detail "$response"
        write_state fatal
        notify "⛔ <b>oci-hunter dừng</b> trên <code>$(hostname)</code>.
Lỗi cấu hình/xác thực — kiểm tra lại .env và <code>oci setup config</code>.
Chi tiết: <code>$(printf '%s' "$response" | tr -d '\n' | cut -c1-300)</code>" loud
        exit 1
        ;;
      network)
        log WARN "Lỗi kết nối tới OCI — sẽ thử lại."
        log_detail "$response"
        sleep_for="$(random_interval)"
        ;;
      *)
        log WARN "Phản hồi lạ — sẽ thử lại."
        log_detail "$response"
        sleep_for="$(random_interval)"
        ;;
    esac

    AD_INDEX=$(( (AD_INDEX + 1) % ad_count ))
    write_state "$result"
    maybe_heartbeat

    log INFO "Chờ ${sleep_for}s trước lần thử tiếp theo..."
    sleep "$sleep_for"
  done
}

case "${1:-}" in
  "")                 main ;;
  --check|--doctor)   doctor ;;
  --telegram-test)    telegram_test ;;
  -h|--help|help)     usage ;;
  *)                  usage; exit 1 ;;
esac
