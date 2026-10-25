SHELL        := /bin/bash
ROOT         := $(CURDIR)
HUNTER       := $(ROOT)/hunter.sh
SETUP        := $(ROOT)/setup.sh
LOG          := $(ROOT)/hunter.log
STATE        := $(ROOT)/.hunter-state
TMUX_SESSION := oci-hunter
SERVICE      := oci-hunter
UNIT_SRC     := $(ROOT)/systemd/oci-hunter.service
UNIT_DST     := /etc/systemd/system/oci-hunter.service
RUN_USER     := $(shell id -un)

.PHONY: help setup doctor run run-bg logs journal status stop restart install uninstall telegram-test test lint

.DEFAULT_GOAL := help

help: ## Hiện danh sách lệnh
	@echo ""
	@echo "  oci-hunter — săn instance Oracle Cloud Always Free"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""

setup: ## Wizard tạo .env (chọn OCID bằng menu)
	@bash $(SETUP)

doctor: ## Kiểm tra .env, quyền OCI, image, subnet, Telegram
	@bash $(HUNTER) --check

run: ## Chạy trực tiếp (Ctrl+C để dừng)
	@if [[ ! -f $(ROOT)/.env ]]; then echo "Chưa có .env — chạy: make setup"; exit 1; fi
	@bash $(HUNTER)

run-bg: ## Chạy nền trong tmux
	@if [[ ! -f $(ROOT)/.env ]]; then echo "Chưa có .env — chạy: make setup"; exit 1; fi
	@if ! command -v tmux >/dev/null 2>&1; then \
		echo "Chưa có tmux. Ubuntu: sudo apt install -y tmux"; exit 1; \
	fi
	@if tmux has-session -t $(TMUX_SESSION) 2>/dev/null; then \
		echo "Phiên tmux '$(TMUX_SESSION)' đang chạy — dùng: make status"; \
	else \
		tmux new-session -d -s $(TMUX_SESSION) "bash $(HUNTER)" && \
		echo "Đã chạy nền trong tmux '$(TMUX_SESSION)'. Theo dõi: make logs"; \
	fi

logs: ## Theo dõi log (tail -f)
	@if [[ -f $(LOG) ]]; then tail -n 40 -F $(LOG); else echo "Chưa có log — chạy 'make run' trước."; fi

journal: ## Theo dõi log qua systemd/journald
	@sudo journalctl -fu $(SERVICE)

status: ## Xem trạng thái, số lần thử, log gần nhất
	@echo ""
	@echo "  --- trạng thái (.hunter-state) ---"
	@if [[ -f $(STATE) ]]; then sed 's/^/    /' $(STATE); else echo "    chưa chạy lần nào"; fi
	@echo ""
	@echo "  --- tmux ---"
	@if command -v tmux >/dev/null 2>&1 && tmux has-session -t $(TMUX_SESSION) 2>/dev/null; then \
		echo "    phiên '$(TMUX_SESSION)': đang chạy"; \
	else \
		echo "    không có phiên tmux"; \
	fi
	@echo "  --- systemd ---"
	@if systemctl is-active --quiet $(SERVICE) 2>/dev/null; then \
		echo "    service '$(SERVICE)': active"; \
	else \
		echo "    service '$(SERVICE)': không active (hoặc chưa cài)"; \
	fi
	@echo "  --- 5 dòng log cuối ---"
	@if [[ -f $(LOG) ]]; then tail -n 5 $(LOG) | sed 's/^/    /'; else echo "    chưa có log"; fi
	@echo ""

stop: ## Dừng tmux + service (nếu có)
	@tmux kill-session -t $(TMUX_SESSION) 2>/dev/null && echo "Đã dừng tmux." || true
	@if systemctl is-active --quiet $(SERVICE) 2>/dev/null; then \
		sudo systemctl stop $(SERVICE); echo "Đã dừng service $(SERVICE)."; \
	else \
		echo "Service không chạy."; \
	fi

restart: ## Khởi động lại service systemd
	@sudo systemctl restart $(SERVICE)
	@echo "Đã restart $(SERVICE). Xem log: make journal"

install: ## Cài systemd service (tự chạy lại khi reboot)
	@if [[ ! -f $(ROOT)/.env ]]; then echo "Chưa có .env — chạy: make setup"; exit 1; fi
	@sed -e 's|__USER__|$(RUN_USER)|g' -e 's|__DIR__|$(ROOT)|g' $(UNIT_SRC) | sudo tee $(UNIT_DST) >/dev/null
	@sudo systemctl daemon-reload
	@sudo systemctl enable --now $(SERVICE)
	@echo ""
	@echo "Đã cài service '$(SERVICE)' cho user '$(RUN_USER)'."
	@echo "  Xem log: make journal   (hoặc: sudo journalctl -fu $(SERVICE))"

uninstall: ## Gỡ systemd service
	@sudo systemctl disable --now $(SERVICE) 2>/dev/null || true
	@sudo rm -f $(UNIT_DST)
	@sudo systemctl daemon-reload
	@echo "Đã gỡ service '$(SERVICE)'."

telegram-test: ## Gửi tin nhắn thử tới Telegram
	@bash $(HUNTER) --telegram-test

test: ## Smoke test offline (mock oci-cli, không cần tài khoản OCI)
	@bash $(ROOT)/tests/test.sh

lint: ## Kiểm tra cú pháp + shellcheck (nếu có)
	@bash -n $(HUNTER) && echo "hunter.sh: cú pháp OK"
	@bash -n $(SETUP) && echo "setup.sh: cú pháp OK"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(HUNTER) $(SETUP) && echo "shellcheck: OK"; \
	else \
		echo "shellcheck chưa cài — bỏ qua (sudo apt install shellcheck)."; \
	fi
