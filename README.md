<div align="center">

# 🪶 oci-hunter

**Săn instance Oracle Cloud Always Free (ARM Ampere A1) bằng một vòng lặp bash tối giản.**

Gọi `oci-cli` theo chu kỳ · log ra file + journald · báo Telegram · tự lùi khi bị rate limit

</div>

---

## Tính năng

| | |
|---|---|
| 🎯 **Săn instance** | Gọi `oci compute instance launch`, xoay qua từng Availability Domain |
| 📜 **Theo dõi log** | `hunter.log` + `journalctl` (khi chạy systemd) — xem từ xa qua SSH |
| 📲 **Telegram** | Báo khi săn được, báo khi bị rate limit, báo cáo định kỳ, cảnh báo khi dừng |
| ⏱️ **Chống rate limit** | Chu kỳ 5–10 phút (cấu hình được) + lùi 15→30 phút khi bị chặn |
| 🧭 **Wizard cấu hình** | `make setup` tự lấy OCID, tự tạo VCN/subnet nếu chưa có |
| 🩺 **Chẩn đoán** | `make doctor` kiểm tra quyền OCI, image, subnet, SSH key, Telegram |
| 🖥️ **systemd** | `make install` để chạy 24/7 và tự khởi động lại sau reboot |

Không phụ thuộc repo/package bên ngoài: chỉ cần `bash`, `oci-cli`, `jq`, `curl` (và `tmux` nếu chạy nền).

### Cấu trúc

```
oci-hunter-tool/
├── hunter.sh                  # vòng lặp săn + báo Telegram
├── setup.sh                   # wizard tạo .env
├── Makefile                   # interface duy nhất: make ...
├── systemd/oci-hunter.service # template service
├── tests/test.sh              # smoke test offline
├── .env.example
└── README.md
```

---

## Yêu cầu

- Tài khoản Oracle Cloud (Always Free).
- `oci-cli` đã cấu hình: `oci setup config` → sinh ra `~/.oci/config`.
- `jq`, `curl`.
- Public key SSH (ví dụ `~/.ssh/id_ed25519.pub`).

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y jq curl tmux

# oci-cli (không cần sudo)
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
oci setup config
```

---

## Bắt đầu trong 3 bước

```bash
make setup      # wizard: chọn compartment / shape / subnet / image / key / Telegram
make doctor     # kiểm tra cấu hình, gửi thử Telegram
make run        # chạy thử ở foreground, Ctrl+C để dừng
```

Chạy dài hạn:

```bash
make install    # systemd: tự chạy lại khi reboot, log vào journald
make journal    # xem log realtime
```

Hoặc chạy nền bằng tmux:

```bash
make run-bg
make logs
make status
```

---

## Cấu hình (`.env`)

`make setup` sinh `.env` với quyền `600`. Các biến chính:

| Biến | Ý nghĩa | Mặc định |
|---|---|---|
| `TENANCY_OCID`, `COMPARTMENT_OCID`, `SUBNET_OCID`, `IMAGE_OCID` | OCID tài nguyên OCI | wizard tự lấy |
| `AVAILABILITY_DOMAINS` | Danh sách AD, cách nhau dấu cách — mỗi lần thử xoay sang AD kế tiếp | wizard tự lấy |
| `SHAPE` | `VM.Standard.A1.Flex` (ARM) hoặc `VM.Standard.E2.1.Micro` | `VM.Standard.A1.Flex` |
| `OCPUS`, `MEMORY_GB` | Cấu hình shape Flex. Always Free tối đa **4 OCPU / 24 GB** | `2` / `12` |
| `DISPLAY_NAME` | Tên instance | `arm-free` |
| `BOOT_VOLUME_SIZE_GB` | Boot volume (GB). Always Free tổng 200 GB | `50` |
| `SSH_PUBLIC_KEY` | Nội dung public key | — |
| `INTERVAL_MIN` / `INTERVAL_MAX` | Khoảng chờ ngẫu nhiên giữa 2 lần thử (giây) | `300` / `600` |
| `RATE_LIMIT_BACKOFF` | Lần đầu bị rate limit thì lùi bao lâu (giây) | `900` |
| `RATE_LIMIT_BACKOFF_MAX` | Mức lùi tối đa khi bị liên tục (giây) | `1800` |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | Thông báo Telegram | trống |
| `HEARTBEAT_MIN` | Báo cáo Telegram mỗi N phút, `0` = tắt | `60` |
| `NOTIFY_URL` | Webhook raw text dự phòng (ntfy.sh, Gotify…) | trống |

> **Về rate limit:** OCI trả `TooManyRequests` khi gọi `instance launch` quá dày. Bản này cố ý giãn nhịp 5–10 phút/lần và lùi 15–30 phút khi bị chặn, nên chạy 24/7 vẫn an toàn. Muốn "hiền" hơn nữa: đặt `INTERVAL_MIN=600`, `INTERVAL_MAX=900`.

---

## Telegram (tuỳ chọn nhưng nên bật)

1. Nhắn **@BotFather** → `/newbot` → lấy **token**.
2. Nhắn bot của bạn một câu bất kỳ (để nó có chat với bạn).
3. Chạy `make setup` và dán token — wizard tự dò `chat_id` qua `getUpdates`.
   Hoặc điền tay: lấy chat id từ **@userinfobot**.
4. Kiểm tra: `make telegram-test`.

Bạn sẽ nhận được:

- 🪶 tin khởi động (kèm shape, chu kỳ),
- ⚠️ cảnh báo rate limit (tối đa 1 lần/30 phút),
- 🕐 báo cáo định kỳ: uptime, số lần thử, AD gần nhất, kết quả gần nhất,
- 🎉 tin chiến thắng kèm instance OCID, IP public và lệnh SSH,
- ⛔ tin báo dừng khi gặp lỗi cấu hình/xác thực.

---

## Cách hoạt động

```
load .env → kiểm tra oci-cli/jq → vòng lặp:
  ├─ chọn AD kế tiếp
  ├─ gọi `oci compute instance launch ...`
  ├─ thành công?  → lấy public IP → báo Telegram → thoát 0
  ├─ hết capacity → xoay AD, chờ 300–600s
  ├─ rate limit    → lùi 900s, gấp đôi (tối đa 1800s), chờ thêm jitter
  ├─ lỗi kết nối   → chờ 300–600s rồi thử lại
  └─ lỗi auth/tham số → log + báo Telegram → thoát 1 (systemd dừng, không spam API)
```

Chi tiết đáng chú ý:

- **Log** ghi đồng thời ra `hunter.log` (luôn ở dạng text thuần) và stdout để journald/tmux bắt được.
- `hunter.log` tự xoay vòng khi vượt 5 MB (`hunter.log.1`).
- **Trạng thái** lưu ở `.hunter-state` (số lần thử, AD, kết quả, PID) — `make status` đọc file này.
- **Không có tiến trình nền ẩn**: chạy foreground, tmux hoặc systemd, đều dễ quan sát.

---

## Lệnh có sẵn

```bash
make help           # danh sách lệnh
make setup          # wizard tạo .env
make doctor         # kiểm tra cấu hình
make run            # chạy foreground
make run-bg         # chạy tmux
make logs           # tail -f hunter.log
make journal        # journalctl -fu oci-hunter
make status         # trạng thái + log cuối
make stop           # dừng tmux + service
make restart        # restart service
make install        # cài systemd
make uninstall      # gỡ systemd
make telegram-test  # gửi tin nhắn thử
make test           # smoke test offline (mock oci-cli, không cần tài khoản)
make lint           # bash -n + shellcheck
```

---

## Chạy trên VPS nhỏ (Always Free Micro)

```bash
# trên máy local
scp -r oci-hunter-tool ubuntu@<ip-vps>:~/

# trên VPS
cd ~/oci-hunter-tool
sudo apt update && sudo apt install -y jq curl tmux
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
oci setup config          # dán tenancy/user/fingerprint/private key
make setup
make doctor
make install

# theo dõi từ máy local
ssh ubuntu@<ip-vps> "sudo journalctl -fu oci-hunter"
```

Lưu ý: private key API (`~/.oci/*.pem`) và `.env` phải nằm trên VPS, **không** commit lên git.

---

## Xử lý sự cố

| Log | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Out of host capacity` | AD đó hết chỗ cho shape/OCPU yêu cầu | Bình thường — cứ để chạy. Thử giảm `OCPUS`/`MEMORY_GB` (ví dụ 2/12) hoặc thêm AD khác. |
| `TooManyRequests` | Gọi API quá dày | Tăng `INTERVAL_MIN/MAX`; tool đã tự lùi 15–30 phút. |
| `NotAuthenticated` / `NotAuthorized` | `~/.oci/config` sai, key hết hạn, thiếu policy | Chạy `oci iam availability-domain list` để kiểm tra; xem lại user/fingerprint. |
| `InvalidParameter` | Shape không hỗ trợ `--shape-config`, image sai kiến trúc, boot volume quá nhỏ | Chạy `make doctor`; chọn lại image ARM cho `A1.Flex`. |
| `RequestException` / timeout | Mạng chập chờn | Tool tự thử lại; kiểm tra DNS/proxy của VPS. |
| Không thấy tin Telegram | Sai token/chat_id, chưa `/start` bot | `make telegram-test` để xem lỗi thật. |

Xem trạng thái nhanh trên server:

```bash
make status
tail -n 50 hunter.log
sudo journalctl -u oci-hunter --since "1 hour ago"
```

---

## Bảo mật & chia sẻ

- `.env`, `hunter.log`, `.hunter-state` đã nằm trong `.gitignore`.
- `.env` chứa token bot → giữ `chmod 600`. Nếu lỡ lộ, thu hồi token bằng `/revoke` với @BotFather.
- Chia sẻ tool cho bạn bè: gửi cả thư mục (hoặc push lên repo riêng của bạn). Mỗi người chạy `make setup` với tài khoản OCI riêng — **không** chia sẻ `.env` hay `~/.oci`.

---

## Giấy phép

MIT — xem [LICENSE](LICENSE).
