#!/usr/bin/env bash
# =============================================================================
#  tests/test.sh — smoke test offline
#
#  Không cần tài khoản OCI: thay `oci` và `curl` bằng script giả để kiểm tra
#  vòng lặp, phân loại lỗi, backoff, state, Telegram, wizard setup.
#
#  Chạy: make test   (hoặc bash tests/test.sh)
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oci-hunter-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  if eval "$2"; then
    printf '  \033[32m✓\033[0m %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

# -----------------------------------------------------------------------------
# Mock oci-cli: đọc hàng đợi phản hồi trong $MOCK_DIR/sequence
# -----------------------------------------------------------------------------
write_mock_oci() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/oci" <<'MOCK'
#!/usr/bin/env bash
dir="${MOCK_DIR:?}"
if [[ "$1" == "compute" && "$2" == "instance" && "$3" == "launch" ]]; then
  IFS=',' read -ra queue <"$dir/sequence"
  head="${queue[0]:-success}"
  if [[ ${#queue[@]} -gt 1 ]]; then
    printf '%s' "$(printf '%s' "${queue[*]:1}" | tr ' ' ',')" >"$dir/sequence"
  else
    printf 'success' >"$dir/sequence"
  fi
  case "$head" in
    capacity) echo "ServiceError: Out of host capacity for shape VM.Standard.A1.Flex"; exit 1 ;;
    throttle) echo "ServiceError: TooManyRequests"; exit 1 ;;
    fatal)    echo "ServiceError: NotAuthenticated"; exit 1 ;;
    network)  echo "RequestException: connection timed out"; exit 1 ;;
    unknown)  echo "weird response"; exit 1 ;;
    success)  printf '%s\n' '{"data":{"id":"ocid1.instance.oc1.ap-singapore-1.TEST","lifecycle-state":"PROVISIONING"}}'; exit 0 ;;
  esac
fi
if [[ "$1" == "compute" && "$2" == "instance" && "$3" == "list-vnics" ]]; then
  printf '%s\n' '{"data":[{"public-ip":"203.0.113.7"}]}'
  exit 0
fi
if [[ "$1" == "iam" && "$2" == "availability-domain" ]]; then
  printf '%s\n' '{"data":[{"name":"xx:ap-singapore-1-AD-1"},{"name":"xx:ap-singapore-1-AD-2"}]}'
  exit 0
fi
if [[ "$1" == "compute" && "$2" == "image" && "$3" == "get" ]]; then
  printf '%s\n' '{"data":{"display-name":"Canonical-Ubuntu-22.04-aarch64","operating-system":"Canonical Ubuntu"}}'
  exit 0
fi
if [[ "$1" == "compute" && "$2" == "image" && "$3" == "list" ]]; then
  printf '%s\n' '{"data":[{"region":"ap-singapore-1"}]}'
  exit 0
fi
if [[ "$1" == "network" && "$2" == "subnet" && "$3" == "get" ]]; then
  printf '%s\n' '{"data":{"display-name":"subnet1","cidr-block":"10.0.0.0/24"}}'
  exit 0
fi
echo "mock oci: unknown: $*" >&2
exit 1
MOCK
  chmod +x "$bin/oci"
}

write_mock_curl() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_CURL_LOG:?}"
printf '%s\n' '{"ok":true}'
MOCK
  chmod +x "$bin/curl"
}

write_env() {
  local file="$1" heartbeat="${2:-1}"
  cat >"$file" <<ENV
TENANCY_OCID="ocid1.tenancy.oc1..test"
COMPARTMENT_OCID="ocid1.compartment.oc1..test"
SUBNET_OCID="ocid1.subnet.oc1..test"
AVAILABILITY_DOMAINS="xx:ap-singapore-1-AD-1 xx:ap-singapore-1-AD-2"
IMAGE_OCID="ocid1.image.oc1..test"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
DISPLAY_NAME="arm-test"
SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@local"
INTERVAL_MIN=1
INTERVAL_MAX=1
RATE_LIMIT_BACKOFF=2
RATE_LIMIT_BACKOFF_MAX=4
TELEGRAM_BOT_TOKEN="123456:TEST"
TELEGRAM_CHAT_ID="42"
HEARTBEAT_MIN=${heartbeat}
ENV
  chmod 600 "$file"
}

# -----------------------------------------------------------------------------
# Suite 1: vòng lặp hunter
# -----------------------------------------------------------------------------
case_dir() {
  local name="$1" sequence="$2"
  local dir="$TMP/$name"
  mkdir -p "$dir/bin" "$dir/mock"
  cp "$REPO/hunter.sh" "$dir/hunter.sh"
  printf '%s' "$sequence" >"$dir/mock/sequence"
  write_mock_oci "$dir/bin"
  write_mock_curl "$dir/bin"
  write_env "$dir/.env"
  printf '%s' "$dir"
}

run_hunter() {
  local dir="$1"
  ( cd "$dir" && MOCK_DIR="$dir/mock" MOCK_CURL_LOG="$dir/curl.log" PATH="$dir/bin:$PATH" \
      bash ./hunter.sh >/dev/null 2>&1 )
}

suite_loop() {
  echo ""
  echo "── Vòng lặp hunter ──"

  local d
  d="$(case_dir happy "capacity,throttle,throttle,success")"
  run_hunter "$d"
  check "capacity+throttle+success: exit 0" "[[ $? -eq 0 ]]"
  check "log báo hết capacity" "grep -q 'Hết capacity' '$d/hunter.log'"
  check "backoff lần đầu 2s" "grep -q 'lùi 2s' '$d/hunter.log'"
  check "backoff gấp đôi lên 4s" "grep -q 'lùi 4s' '$d/hunter.log'"
  check "nhận diện thành công" "grep -q 'SĂN ĐƯỢC INSTANCE' '$d/hunter.log'"
  check "lấy public IP + lệnh SSH" "grep -q 'ssh ubuntu@203.0.113.7' '$d/hunter.log'"
  check "state ghi attempts=4" "grep -q '^attempts=4$' '$d/.hunter-state'"
  check "state ghi success" "grep -q '^last_result=success$' '$d/.hunter-state'"
  check "Telegram nhận >=3 tin" "[[ \$(grep -c sendMessage '$d/curl.log') -ge 3 ]]"
  check "Telegram có tin chiến thắng" "grep -q 'Săn được OCI ARM' '$d/curl.log'"

  d="$(case_dir fatal "fatal")"
  run_hunter "$d"
  check "lỗi auth: exit 1" "[[ $? -eq 1 ]]"
  check "lỗi auth: state=fatal" "grep -q '^last_result=fatal$' '$d/.hunter-state'"
  check "lỗi auth: báo Telegram" "grep -q 'oci-hunter dừng' '$d/curl.log'"

  d="$(case_dir unknown "unknown,success")"
  run_hunter "$d"
  check "phản hồi lạ: vẫn thử lại và thắng" "grep -q 'SĂN ĐƯỢC INSTANCE' '$d/hunter.log'"

  d="$(case_dir network "network,success")"
  run_hunter "$d"
  check "lỗi mạng: vẫn thử lại và thắng" "grep -q 'SĂN ĐƯỢC INSTANCE' '$d/hunter.log'"
}

# -----------------------------------------------------------------------------
# Suite 2: CLI (--help, --check, thiếu .env)
# -----------------------------------------------------------------------------
suite_cli() {
  echo ""
  echo "── CLI ──"

  bash "$REPO/hunter.sh" --help >/dev/null 2>&1
  check "--help exit 0" "[[ $? -eq 0 ]]"

  local dir="$TMP/noenv"
  mkdir -p "$dir"
  cp "$REPO/hunter.sh" "$dir/hunter.sh"
  ( cd "$dir" && bash ./hunter.sh >/dev/null 2>&1 )
  check "thiếu .env: exit 1" "[[ $? -eq 1 ]]"

  dir="$TMP/doctor"
  mkdir -p "$dir/bin" "$dir/mock"
  cp "$REPO/hunter.sh" "$dir/hunter.sh"
  write_mock_oci "$dir/bin"
  write_mock_curl "$dir/bin"
  write_env "$dir/.env"
  ( cd "$dir" && MOCK_DIR="$dir/mock" MOCK_CURL_LOG="$dir/curl.log" PATH="$dir/bin:$PATH" \
      bash ./hunter.sh --check >"$dir/out.log" 2>&1 )
  check "--check exit 0" "[[ $? -eq 0 ]]"
  check "--check xác nhận AD hợp lệ" "grep -q 'AD hợp lệ' '$dir/out.log'"
  check "--check đọc được image/subnet" "grep -q 'Subnet: subnet1' '$dir/out.log'"
}

# -----------------------------------------------------------------------------
# Suite 3: wizard setup.sh (cần pty)
# -----------------------------------------------------------------------------
suite_setup() {
  echo ""
  echo "── Wizard setup ──"

  if ! command -v script >/dev/null 2>&1; then
    echo "  (bỏ qua: không có lệnh 'script' để tạo pty)"
    return 0
  fi

  local d="$TMP/setup"
  mkdir -p "$d/bin" "$d/home/.oci" "$d/home/.ssh"
  cp "$REPO/setup.sh" "$d/setup.sh"
  printf 'tenancy=ocid1.tenancy.oc1..test\nregion=ap-singapore-1\n' >"$d/home/.oci/config"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA test@local\n' >"$d/home/.ssh/id_ed25519.pub"

  cat >"$d/bin/oci" <<MOCK
#!/usr/bin/env bash
echo "\$*" >> "$d/oci.log"
case "\$*" in
  *"--version"*) echo "3.0.0" ;;
  *"availability-domain list"*) echo '{"data":[{"name":"xx:ap-singapore-1-AD-1"},{"name":"xx:ap-singapore-1-AD-2"}]}' ;;
  *"compartment list"*) echo '{"data":[{"name":"mycomp","id":"ocid1.compartment.oc1..abc"}]}' ;;
  *"vcn list"*) echo '{"data":[{"id":"ocid1.vcn.oc1..v","display-name":"vcn1","cidr-block":"10.0.0.0/16","compartment-id":"ocid1.tenancy.oc1..test"}]}' ;;
  *"subnet list"*) echo '{"data":[{"id":"ocid1.subnet.oc1..s","display-name":"subnet1","cidr-block":"10.0.0.0/24","prohibit-public-ip-on-vnic":false}]}' ;;
  *"image list"*) echo '{"data":[{"id":"ocid1.image.oc1..i1","display-name":"Canonical-Ubuntu-22.04-aarch64"}]}' ;;
  *) echo "mock oci unknown: \$*" >&2; exit 1 ;;
esac
MOCK
  chmod +x "$d/bin/oci"

  # compartment 0, shape 0, ocpu/ram/boot Enter, image 0, ssh Enter,
  # token Enter, 5 tham số Enter, tên Enter
  printf '0\n0\n\n\n\n0\n\n\n\n\n\n\n\n' | \
    HOME="$d/home" PATH="$d/bin:$PATH" script -qec "bash $d/setup.sh" /dev/null >"$d/out.log" 2>&1
  check "setup: exit 0" "[[ $? -eq 0 ]]"
  check "setup: tạo .env quyền 600" "[[ \$(stat -c %a '$d/.env' 2>/dev/null) == 600 ]]"
  check "setup: lấy đúng subnet" "grep -q '^SUBNET_OCID=\"ocid1.subnet.oc1..s\"' '$d/.env'"
  check "setup: chọn image đầu tiên" "grep -q '^IMAGE_OCID=\"ocid1.image.oc1..i1\"' '$d/.env'"
  check "setup: chu kỳ mặc định 300-600s" "grep -q '^INTERVAL_MIN=300$' '$d/.env' && grep -q '^INTERVAL_MAX=600$' '$d/.env'"
  check "setup: backoff mặc định 900/1800" "grep -q '^RATE_LIMIT_BACKOFF=900$' '$d/.env' && grep -q '^RATE_LIMIT_BACKOFF_MAX=1800$' '$d/.env'"
  check "setup: AD lấy tự động" "grep -q 'AD-1 xx:ap-singapore-1-AD-2' '$d/.env'"
  check "setup: SSH key lấy từ file" "grep -q '^SSH_PUBLIC_KEY=\"ssh-ed25519' '$d/.env'"
}

# -----------------------------------------------------------------------------
suite_lint() {
  echo ""
  echo "── Cú pháp / shellcheck ──"
  bash -n "$REPO/hunter.sh" && check "hunter.sh cú pháp OK" "true" || check "hunter.sh cú pháp OK" "false"
  bash -n "$REPO/setup.sh" && check "setup.sh cú pháp OK" "true" || check "setup.sh cú pháp OK" "false"

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$REPO/hunter.sh" "$REPO/setup.sh" >/dev/null 2>&1
    check "shellcheck không có cảnh báo" "[[ $? -eq 0 ]]"
  else
    echo "  (bỏ qua shellcheck: chưa cài)"
  fi
}

printf '\n\033[1moci-hunter — smoke tests\033[0m\n'
suite_lint
suite_cli
suite_loop
suite_setup

echo ""
printf 'Kết quả: \033[32m%d pass\033[0m, \033[31m%d fail\033[0m\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
