#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Minimal Linux Setup
#  - XFCE4 desktop via Termux-X11
#  - GPU acceleration (Turnip/Zink)
#  - Proot Ubuntu container
#  - Không cài app thừa — cài sau tùy nhu cầu
#######################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { echo -e "${RED}[-]${NC} $1"; exit 1; }

# ============================================================
#  BƯỚC 1 — Cập nhật Termux
# ============================================================
log "Cập nhật package Termux..."
pkg update -y && pkg upgrade -y

# ============================================================
#  BƯỚC 2 — Thêm repo X11 + TUR
# ============================================================
log "Thêm repo X11 và TUR..."
pkg install -y x11-repo tur-repo

# ============================================================
#  BƯỚC 3 — Cài Termux-X11 và XFCE4
# ============================================================
log "Cài Termux-X11..."
pkg install -y termux-x11-nightly

log "Cài XFCE4 desktop (tối thiểu)..."
pkg install -y \
    xfce4 \
    xfce4-terminal \
    thunar

# ============================================================
#  BƯỚC 4 — GPU acceleration
# ============================================================
log "Cài GPU driver..."
GPU_VENDOR=$(getprop ro.hardware.egl 2>/dev/null || echo "")

log "Cài mesa-zink..."
pkg install -y mesa-zink

# vulkan-loader-android và vulkan-loader-generic xung đột nhau
# Chỉ cài một cái — ưu tiên android loader, fallback sang generic nếu lỗi
if pkg install -y vulkan-loader-android 2>/dev/null; then
    ok "Cài vulkan-loader-android thành công"
else
    warn "vulkan-loader-android bị conflict, thử vulkan-loader-generic..."
    pkg install -y vulkan-loader-generic 2>/dev/null || \
        warn "Không cài được Vulkan loader — GPU acceleration có thể không hoạt động"
fi

if [[ "$GPU_VENDOR" == *"adreno"* ]]; then
    pkg install -y mesa-vulkan-icd-freedreno 2>/dev/null && \
        ok "Phát hiện GPU Adreno — cài Turnip driver" || \
        warn "Không cài được Turnip driver"
else
    warn "GPU không phải Adreno — dùng Zink/LLVMpipe fallback"
fi

# ============================================================
#  BƯỚC 5 — Audio
# ============================================================
log "Cài PulseAudio..."
pkg install -y pulseaudio

# ============================================================
#  BƯỚC 6 — Proot Ubuntu
# ============================================================
log "Cài proot-distro..."
pkg install -y proot proot-distro

log "Tải Ubuntu 22.04 (có thể mất vài phút)..."
proot-distro install ubuntu || warn "Ubuntu đã cài rồi, bỏ qua."

log "Cập nhật Ubuntu và cài package cần thiết..."
proot-distro login ubuntu -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q --no-install-recommends \
        sudo curl wget git nano dbus-x11
" || warn "Một số package proot có thể lỗi, kiểm tra lại sau."

# ============================================================
#  BƯỚC 7 — GPU env config
# ============================================================
log "Tạo file cấu hình GPU..."
mkdir -p ~/.config
cat > ~/.config/linux-gpu.sh << 'EOF'
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export ZINK_DESCRIPTORS=lazy
export MESA_VK_WSI_PRESENT_MODE=immediate
export XDG_DATA_DIRS=/data/data/com.termux/files/usr/share:${XDG_DATA_DIRS}
export XDG_CONFIG_DIRS=/data/data/com.termux/files/usr/etc/xdg:${XDG_CONFIG_DIRS}
EOF

# ============================================================
#  BƯỚC 8 — Script khởi động / dừng
# ============================================================
log "Tạo script start/stop..."

cat > ~/start-desktop.sh << 'STARTEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Đang khởi động XFCE4..."

source ~/.config/linux-gpu.sh 2>/dev/null

# Dọn tiến trình cũ
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "xfce4-session" 2>/dev/null || true

# Khởi động audio
pulseaudio --kill 2>/dev/null || true
sleep 0.5
pulseaudio --start --exit-idle-time=-1
sleep 1
pactl load-module module-native-protocol-tcp \
    auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
export PULSE_SERVER=127.0.0.1

# Khởi động Termux-X11
termux-x11 :0 -ac &
sleep 3
export DISPLAY=:0

echo ""
echo "==================================="
echo "  Mở app Termux-X11 để thấy màn hình"
echo "==================================="
echo ""

exec startxfce4
STARTEOF
chmod +x ~/start-desktop.sh

cat > ~/stop-desktop.sh << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Dừng desktop..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "xfce4-session" 2>/dev/null || true
pkill -9 -f "pulseaudio" 2>/dev/null || true
echo "Xong."
STOPEOF
chmod +x ~/stop-desktop.sh

cat > ~/proot-shell.sh << 'PROOFEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Vào Ubuntu proot với DISPLAY bind sẵn
TERMUX_TMP="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
BINDS=""
[ -d "$TERMUX_TMP/.X11-unix" ] && BINDS="$BINDS --bind $TERMUX_TMP/.X11-unix:/tmp/.X11-unix"
[ -d "/dev/dri" ]               && BINDS="$BINDS --bind /dev/dri:/dev/dri"

proot-distro login ubuntu $BINDS -- bash -c "
    export DISPLAY=:0
    export MESA_NO_ERROR=1
    export GALLIUM_DRIVER=zink
    exec bash
"
PROOFEOF
chmod +x ~/proot-shell.sh

# ============================================================
#  XONG
# ============================================================
echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${WHITE}  Cài đặt hoàn tất!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "  ${CYAN}Khởi động desktop:${NC}"
echo -e "    ${WHITE}bash ~/start-desktop.sh${NC}"
echo -e "    → Rồi mở app Termux-X11"
echo ""
echo -e "  ${CYAN}Vào Ubuntu shell:${NC}"
echo -e "    ${WHITE}bash ~/proot-shell.sh${NC}"
echo ""
echo -e "  ${CYAN}Dừng desktop:${NC}"
echo -e "    ${WHITE}bash ~/stop-desktop.sh${NC}"
echo ""
echo -e "  ${YELLOW}Cài thêm app Termux:${NC}  pkg install <tên>"
echo -e "  ${YELLOW}Cài thêm app Ubuntu:${NC}  bash ~/proot-shell.sh → apt install <tên>"
echo ""
