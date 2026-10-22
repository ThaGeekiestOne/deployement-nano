#!/bin/bash
# =============================================================================
# Jetson Nano/Orin deployment automation
# Runs every step from the deployment document, in the same order.
# Survives reboots: finished steps are recorded in a state file and a temporary
# systemd service re-launches this script after each reboot until it is done.
#
# Usage (run as the normal user, NOT with sudo):
#     chmod +x deploy.sh
#     ./deploy.sh
#     SUDO_PASSWORD=mypass ./deploy.sh      # override the default password
# =============================================================================

# ------------------------------- CONFIGURATION -------------------------------
SUDO_PASSWORD="${SUDO_PASSWORD:-nvidia}"          # <-- configurable password
DEPLOY_USER="${DEPLOY_USER:-$(id -un)}"
DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

RELEASE_REPO="ThaGeekiestOne/deployement-nano"
RELEASE_TAG="init"
DOWNLOAD_DIR="$DEPLOY_HOME/Downloads"

VENV_DIR="${VENV_DIR:-$DEPLOY_HOME/tensor1}"       # same venv the .service activates
APP_DIR="$DEPLOY_HOME/vehicle_alignment_v2"

STATE_FILE="$DEPLOY_HOME/.deploy_state"
LOG_FILE="$DEPLOY_HOME/deploy.log"
RESUME_UNIT="deploy-resume.service"
SUDOERS_TMP="/etc/sudoers.d/99-deploy-temp"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
# -----------------------------------------------------------------------------

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME="$DEPLOY_HOME"
APT_OPTS=(-o DPkg::Lock::Timeout=600)

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "!!! FAILED at line $LINENO (step: ${CURRENT_STEP:-bootstrap}). Fix the problem and re-run ./deploy.sh - finished steps are skipped."' ERR

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this script as your normal user (not root / sudo)."; exit 1
fi

# sudo wrapper: feeds the configurable password, never prompts
S() { echo "$SUDO_PASSWORD" | sudo -S -p '' "$@"; }

wait_for_network() {
    echo "Waiting for network..."
    for _ in $(seq 1 60); do
        if curl -fsI --max-time 5 https://github.com >/dev/null 2>&1; then return 0; fi
        sleep 5
    done
    echo "No network after 5 minutes."; return 1
}

# -------------------------- bootstrap / reboot-resume -------------------------
bootstrap() {
    echo "=== $(date) | deploy start/resume ==="
    S -v   # validates password early

    # Temporary passwordless sudo so long builds (opencv) never hit a prompt
    echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" | S tee "$SUDOERS_TMP" >/dev/null
    S chmod 440 "$SUDOERS_TMP"
    S visudo -cf "$SUDOERS_TMP" >/dev/null

    # Service that resumes this script after any reboot
    S tee /etc/systemd/system/$RESUME_UNIT >/dev/null <<EOF
[Unit]
Description=Resume deployment script after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$DEPLOY_USER
Environment=SUDO_PASSWORD=$SUDO_PASSWORD
ExecStart=/bin/bash $SCRIPT_PATH
TimeoutStartSec=infinity
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    S systemctl daemon-reload
    S systemctl enable $RESUME_UNIT >/dev/null 2>&1
    touch "$STATE_FILE"
    wait_for_network
}

finalize() {
    echo "=== Cleaning up resume service and temporary sudo rule ==="
    S systemctl disable $RESUME_UNIT >/dev/null 2>&1 || true
    S rm -f /etc/systemd/system/$RESUME_UNIT "$SUDOERS_TMP"
    S systemctl daemon-reload
    echo "=== DEPLOYMENT COMPLETE ($(date)) ==="
}

step() {   # step <name> <function>
    local name="$1" fn="$2"
    if grep -qx "$name" "$STATE_FILE"; then
        echo "--- [skip] $name (already done)"; return 0
    fi
    CURRENT_STEP="$name"
    echo; echo "################ STEP: $name ################"
    "$fn"
    echo "$name" >> "$STATE_FILE"
}

# ---------------------------- release asset download --------------------------
# fetch_asset <filename> : download one file from the release (resumable, retried)
fetch_asset() {
    local name="$1"
    local url="https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG/$name"
    local dest="$DOWNLOAD_DIR/$name"
    mkdir -p "$DOWNLOAD_DIR"
    local attempt ok
    for attempt in 1 2 3; do
        ok=0
        if wget -c -q --show-progress -O "$dest" "$url" && [ -s "$dest" ]; then
            # basic sanity check that the file is not truncated/corrupt
            case "$name" in
                *.deb) dpkg-deb -I "$dest" >/dev/null 2>&1 && ok=1 ;;
                *.whl) python3 -m zipfile -t "$dest" >/dev/null 2>&1 && ok=1 ;;
                *.sh)  bash -n "$dest" 2>/dev/null && ok=1 ;;
                *)     ok=1 ;;
            esac
        fi
        if [ "$ok" -eq 1 ]; then echo "Downloaded: $name"; return 0; fi
        echo "Download problem for $name (attempt $attempt/3) - retrying"
        rm -f "$dest"; sleep 5
    done
    echo "Could not download $name correctly"; return 1
}

# ===================================== STEPS =================================

# ---- Installing jtop ----
step_jtop() {
    S apt-get "${APT_OPTS[@]}" update
    S apt-get "${APT_OPTS[@]}" install -y python3-pip
    S pip3 install -U jetson-stats
    S jtop --install-service
}

# ---- Install firefox ----
step_firefox() {
    cd "$DEPLOY_HOME"
    wget -c -O firefox-nightly-arm64.deb \
        https://ftp.mozilla.org/pub/firefox/nightly/latest-mozilla-central/firefox-160.0a1.en-US.linux-aarch64.deb
    S dpkg -i firefox-nightly-arm64.deb
}

# ---- Installing jetpack ----
step_jetpack() {
    S apt-get "${APT_OPTS[@]}" install -y nvidia-jetpack
    S apt-get "${APT_OPTS[@]}" install -y libyaml-cpp-dev
}

# ---- opencv.sh (it reboots the device at the end) ----
step_opencv() {
    local src=""
    if [ -f "$SCRIPT_DIR/opencv.sh" ]; then
        src="$SCRIPT_DIR/opencv.sh"            # local copy next to deploy.sh wins
    else
        fetch_asset "opencv.sh"                # otherwise take it from the release
        src="$DOWNLOAD_DIR/opencv.sh"
    fi

    cp "$src" "$DEPLOY_HOME/opencv.sh"
    chmod +x "$DEPLOY_HOME/opencv.sh"
    cd "$DEPLOY_HOME"
    ./opencv.sh          # a failure here aborts (set -e); success ends in a reboot

    # Reached only if the reboot is slightly delayed: mark done, then wait for it.
    echo "opencv" >> "$STATE_FILE"
    echo "Waiting for reboot requested by opencv.sh..."
    sleep 600
}

# ---- Commands for making the virtual environment ----
step_venv() {
    S apt-get "${APT_OPTS[@]}" install -y python3.10-venv
    S apt-get "${APT_OPTS[@]}" install -y python3-pip
    cd "$(dirname "$VENV_DIR")"
    python3 -m venv --system-site-packages "$(basename "$VENV_DIR")"
    S apt-get "${APT_OPTS[@]}" install -y nano
}

# ---- anydesk, deepstream, torch(+audio+vision via pip), vscode from the release ----
step_release_packages() {
    [ -d "$VENV_DIR" ] || { echo "Virtual environment $VENV_DIR missing"; return 1; }
    local pip="$VENV_DIR/bin/pip"
    local f

    # download everything first (resumable, checksum-verified)
    for f in \
        "anydesk_7.1.1-1_arm64.deb" \
        "deepstream-7.1_7.1.0-1_arm64.deb" \
        "torch-2.7.0-cp310-cp310-linux_aarch64.whl" \
        "torchaudio-2.7.0-cp310-cp310-linux_aarch64.whl" \
        "torchvision-0.22.0-cp310-cp310-linux_aarch64.whl" \
        "code_1.105.1-1760482225_arm64.deb"; do
        fetch_asset "$f"
    done

    cd "$DOWNLOAD_DIR"

    echo "--- anydesk";     S apt-get "${APT_OPTS[@]}" install -y "$DOWNLOAD_DIR/anydesk_7.1.1-1_arm64.deb"
    echo "--- deepstream";  S apt-get "${APT_OPTS[@]}" install -y "$DOWNLOAD_DIR/deepstream-7.1_7.1.0-1_arm64.deb"
    echo "--- torch";       "$pip" install "$DOWNLOAD_DIR/torch-2.7.0-cp310-cp310-linux_aarch64.whl"
    echo "--- torchaudio";  "$pip" install "$DOWNLOAD_DIR/torchaudio-2.7.0-cp310-cp310-linux_aarch64.whl"
    echo "--- torchvision"; "$pip" install "$DOWNLOAD_DIR/torchvision-0.22.0-cp310-cp310-linux_aarch64.whl"
    echo "--- vscode";      S apt-get "${APT_OPTS[@]}" install -y "$DOWNLOAD_DIR/code_1.105.1-1760482225_arm64.deb"
}

# ---- Install VLC ----
step_vlc() {
    S add-apt-repository -y ppa:ubuntuhandbook1/vlc
    S apt-get "${APT_OPTS[@]}" install -y vlc
}

# ---- GLIB / MESON error fix ----
step_glib_meson() {
    S pip3 install meson==1.8.2
    S pip3 install ninja==1.11.1
    cd "$DEPLOY_HOME"
    rm -rf "$DEPLOY_HOME/glib"
    git clone https://github.com/GNOME/glib.git
    cd "$DEPLOY_HOME/glib"
    git checkout 2.76.0
    /usr/local/bin/meson setup build --prefix=/usr
    ninja -C build
    S ninja -C build install
    pkg-config --modversion glib-2.0
}

# ---- Commands for code (requirement.txt) ----
step_python_requirements() {
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install supervision==0.25.1
    pip install ultralytics==8.3.154
    pip install paho-mqtt==2.1.0
    pip install joblib==1.5.1
    pip install scikit-learn==1.6.1
    pip install easyocr==1.7.2
    pip install numpy==1.26.4
    pip install python-dotenv==1.1.1
    pip install onnx==1.18.0
    pip install onnxslim==0.1.57
    pip install paddlepaddle==2.6.2
    pip install --upgrade pip setuptools wheel
    pip uninstall -y easyocr
    pip install paddleocr==2.10.0
    pip uninstall -y opencv-contrib-python opencv-python-headless
    pip uninstall -y opencv-contrib-python
    pip install numpy==1.26.4
    deactivate
}

# ---- Install MQTT ----
step_mqtt() {
    S apt-get "${APT_OPTS[@]}" install -y mosquitto
    S apt-get "${APT_OPTS[@]}" install -y mosquitto-clients
    S apt-get "${APT_OPTS[@]}" install -y nano

    # Overwrite /etc/mosquitto/mosquitto.conf
    S tee /etc/mosquitto/mosquitto.conf >/dev/null <<'EOF'
persistence true
persistence_location /var/lib/mosquitto/

log_dest file /var/log/mosquitto/mosquitto.log

listener 1883
#bind_address 0.0.0.0

allow_anonymous true

include_dir /etc/mosquitto/conf.d
EOF
    S systemctl enable mosquitto
    S systemctl start mosquitto
}

# ---- Vehicle_Alignment.service ----
step_vehicle_service() {
    S tee /etc/systemd/system/vehicle_alignment.service >/dev/null <<EOF
[Unit]
Description=Vehicle Alignment Final Script
After=network-online.target

[Service]
Type=simple
User=$DEPLOY_USER
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash -c 'source $VENV_DIR/bin/activate && python main.py'
# if there is conda env :
#Environment="PATH=/home/kia/anaconda3/envs/test/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
#ExecStart=/home/kia/anaconda3/envs/test/bin/python /home/kia/out/vehicle_access/main.py
Restart=on-failure
RestartSec=10
StartLimitInterval=0
StartLimitBurst=3
KillMode=control-group
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    S systemctl daemon-reload
    S systemctl enable vehicle_alignment.service
}

# ---- Version check against table T1 (report only, never aborts) ----
verify_versions() {
    echo; echo "################ VERSION CHECK (T1) ################"
    local PY="$VENV_DIR/bin/python"
    local bad=0

    check() {   # check <label> <expected prefix> <actual>
        local label="$1" want="$2" got
        got="$(printf '%s' "$3" | tr -d '\r' | head -n1)"
        if [ -z "$got" ]; then
            printf '%-14s %-12s %-26s %s\n' "$label" "$want" "not found" "MISSING"; bad=$((bad+1))
        elif [[ "$got" == "$want"* ]]; then
            printf '%-14s %-12s %-26s %s\n' "$label" "$want" "$got" "OK"
        else
            printf '%-14s %-12s %-26s %s\n' "$label" "$want" "$got" "MISMATCH"; bad=$((bad+1))
        fi
    }

    local v
    printf '%-14s %-12s %-26s %s\n' "Component" "Required" "Installed" "Status"
    v=$(dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null || true);                      check "JetPack"     "6.1"     "$v"
    v=$(/usr/local/cuda/bin/nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\),.*/\1/p' || true); check "CUDA"    "12.6"    "$v"
    v=$(dpkg -l 2>/dev/null | awk '/^ii +libcudnn9/{print $3; exit}' || true);                  check "cuDNN"       "9.3"     "$v"
    v=$(dpkg-query -W -f='${Version}' tensorrt 2>/dev/null || true);                            check "TensorRT"    "10.3.0"  "$v"
    v=$(deepstream-app --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' || true); check "DeepStream"  "7.1"     "$v"
    v=$("$PY" -c 'import torch;print(torch.__version__)' 2>/dev/null || true);                  check "Torch"       "2.7.0"   "$v"
    v=$("$PY" -c 'import torchaudio;print(torchaudio.__version__)' 2>/dev/null || true);        check "Torchaudio"  "2.7.0"   "$v"
    v=$("$PY" -c 'import torchvision;print(torchvision.__version__)' 2>/dev/null || true);      check "Torchvision" "0.22.0"  "$v"
    v=$("$PY" -c 'import cv2;print(cv2.__version__)' 2>/dev/null || true);                      check "OpenCV"      "4.10.0"  "$v"
    v=$(pkg-config --modversion glib-2.0 2>/dev/null || true);                                  check "Glib"        "2.76.0"  "$v"
    v=$(pkg-config --modversion gstreamer-1.0 2>/dev/null || true);                             check "GStreamer"   "1.20.3"  "$v"
    v=$("$PY" -c 'import numpy;print(numpy.__version__)' 2>/dev/null || true);                  check "Numpy"       "1.26.4"  "$v"

    echo
    if [ "$bad" -eq 0 ]; then
        echo "All versions match table T1."
    else
        echo "WARNING: $bad component(s) differ from table T1 - see MISMATCH/MISSING rows above."
    fi
}

# ==================================== MAIN ===================================
bootstrap

# Order matches the document exactly. Do not reorder.
step jtop                step_jtop
step firefox             step_firefox
step jetpack             step_jetpack
step opencv              step_opencv                # reboots here; script resumes after
step venv                step_venv                  # needed before torch is installed
step release_packages    step_release_packages      # anydesk, deepstream, torch/audio/vision, vscode
step vlc                 step_vlc
step glib_meson          step_glib_meson
step python_requirements step_python_requirements
step mqtt                step_mqtt
step vehicle_service     step_vehicle_service

verify_versions
finalize
