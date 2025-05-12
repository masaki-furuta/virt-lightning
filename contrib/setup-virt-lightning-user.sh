#!/bin/bash
#
# setup-virt-lightning-user.sh - user local quick installer for virt-lightning
#
# This helper script prepares virt-lightning in user-space (~/.local/share/virt-lightning/)
# without modifying system-wide libvirt settings.
#
# Features:
# - Check libvirt/qemu installation
# - Ensure user belongs to 'libvirt' group
# - Install pipx + virt-lightning
# - Create local pool and adjust permissions based on qemu user/group
# - Provide helper commands for distro list, start/stop, ssh
#
# Usage:
#   bash contrib/setup-virt-lightning-user.sh
#
# Optional Uninstall:
#   sudo apt purge -y libvirt-daemon libvirt-clients libvirt-dev libvirt-daemon-system qemu-kvm virtinst python3-venv pipx
#   sudo apt autoremove -y
#   sudo rm -rfv /var/lib/libvirt /etc/libvirt /var/run/libvirt ~/.config/virt-lightning ~/.config/libvirt ~/.local/share/virt-lightning
#   sudo ip link delete virt-lightning type bridge
#   sudo pkill dnsmasq
#   for m in $(machinectl list --no-legend | awk '{print $1}' | grep virt-lightning); do sudo machinectl terminate $m; done
#
# Manual permission setup (if needed):
#   mkdir -pv ~/.local/share/virt-lightning/pool/upstream
#   sudo chown -Rv libvirt-qemu:kvm ~/.local/share/virt-lightning/pool
#   sudo chown -Rv $USER ~/.local/share/virt-lightning/pool/upstream
#   sudo chmod -v 775 ~/.local/share/virt-lightning ~/.local/share/virt-lightning/pool ~/.local/share/virt-lightning/pool/upstream
#   sudo chown -v libvirt-qemu:kvm ~/.local/share/virt-lightning/pool/*.qcow2
#   sudo chmod -v 660 ~/.local/share/virt-lightning/pool/*.qcow2
#
# Permission check example:
#   sudo su - libvirt-qemu -s /bin/bash -c "ls -l ~/.local/share/virt-lightning/pool/*.qcow2; echo; ls -l ~/.local/share/virt-lightning/pool/upstream/*.qcow2"
#

set -e

VL_BIN="vl"
DISTRO_IMAGE_PATH="$HOME/.local/share/virt-lightning/images/upstream"
CONFIG_DIR="$HOME/.config/virt-lightning"
CONFIG_FILE="$CONFIG_DIR/config.ini"
IMAGES_URL="https://virt-lightning.org/images/"

echo "virt-lightning user environment setup tool (v4.1a)"

# -------------------------------
# libvirt base packages
# -------------------------------
install_packages() {
    echo "Checking required packages..."
    if ! command -v virsh >/dev/null 2>&1; then
        echo "Installing libvirt base packages..."
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y libvirt libvirt-client libvirt-devel gcc python3-devel qemu-kvm virt-install genisoimage
        elif command -v apt >/dev/null 2>&1; then
            sudo apt update
            sudo apt install -y python3-venv pkg-config gcc libvirt-dev python3-dev libvirt-clients libvirt-daemon-system qemu-system-x86 virtinst genisoimage
        else
            echo "Unsupported package manager. Please install manually."
            exit 1
        fi
    fi

    if systemctl list-unit-files | grep -q libvirtd.service; then
        sudo systemctl enable --now libvirtd.service
    elif systemctl list-unit-files | grep -q libvirtd.socket; then
        sudo systemctl enable --now libvirtd.socket
    fi
}

# -------------------------------
# libvirt group check
# -------------------------------
check_libvirt_group() {
    if ! id -nG "$USER" | grep -qw libvirt; then
        echo "User $USER is not in libvirt group. Adding..."
        sudo usermod -aG libvirt "$USER"
        echo "===================================================="
        echo "You have been added to libvirt group."
        echo "Please logout/login (or reboot) and rerun this command."
        echo "===================================================="
        exit 0
    fi
}

# -------------------------------
# pipx + virt-lightning
# -------------------------------
install_virt_lightning() {
    if ! command -v pipx >/dev/null 2>&1; then
        echo "Installing pipx..."
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y pipx
        elif command -v apt >/dev/null 2>&1; then
            sudo apt update
            sudo apt install -y pipx
        else
            echo "Install pipx manually."
            exit 1
        fi
    fi

    if ! pipx list | grep -q virt-lightning; then
        echo "Installing virt-lightning via pipx..."
        # パッチ版を追加する場合はこちら
        # pipx install git+https://github.com/masaki-furuta/virt-lightning.git
    fi

    # ✅ custom vl remote_distro_list 対応
    echo "Injecting requests library for custom remote_distro_list..."
    pipx inject virt-lightning requests || true
}

# -------------------------------
# user dir + config.ini
# -------------------------------
prepare_user_dir() {
    echo "Creating user virt-lightning directories..."
    mkdir -p "$DISTRO_IMAGE_PATH"
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Creating default config.ini..."
        cat > "$CONFIG_FILE" <<EOF
[main]
storage_dir = $HOME/.local/share/virt-lightning/pool
EOF
    fi
}

# -------------------------------
# o+x permission fix
# -------------------------------
fix_permissions() {
    # qemu user/group 権限も virt-lightning の default に合わせて調整
    echo "Checking qemu user/group ownership..."
    QEMU_DIR="/var/lib/libvirt/qemu/"
    if [ -d "$QEMU_DIR" ]; then
        qemu_user=$(stat -c '%U' "$QEMU_DIR")
        qemu_group=$(stat -c '%G' "$QEMU_DIR")
        echo "Detected qemu user: $qemu_user, group: $qemu_group"
    
        sudo mkdir -p "$HOME/.local/share/virt-lightning/pool/upstream"
        sudo chown -Rv "$qemu_user:$qemu_group" "$HOME/.local/share/virt-lightning/pool"
        sudo chown -Rv "$USER" "$HOME/.local/share/virt-lightning/pool/upstream"
        sudo chmod -v 775 "$HOME/.local/share/virt-lightning" "$HOME/.local/share/virt-lightning/pool" "$HOME/.local/share/virt-lightning/pool/upstream"
    else
        echo "[WARN] $QEMU_DIR not found. Skipping qemu user/group fix."
    fi

    echo "Applying o+x permissions for libvirt-qemu access..."
    sudo chmod -v o+x /home /home/$USER /home/$USER/.local /home/$USER/.local/share /home/$USER/.local/share/virt-lightning

    echo ">>> current permissions:"
    ls -ld /home /home/$USER /home/$USER/.local /home/$USER/.local/share /home/$USER/.local/share/virt-lightning
}

# -------------------------------
# online distro list
# -------------------------------
list_online_distros() {
    echo "Fetching available distros from $IMAGES_URL..."
    curl -s $IMAGES_URL | grep -oP '(?<=<li>)(.*?)(?=</li>)' | sort
}

# -------------------------------
# menu
# -------------------------------
main_menu() {
    echo ""
    echo "virt-lightning setup complete!"
    echo "=============================="
    echo "Available commands:"
    echo "  vl distro_list               : Show local images"
    echo "  vl fetch <distro>            : Download image"
    echo "  vl up                        : Start VMs defined in virt-lightning.yaml"
    echo "  vl down                      : Stop all running VMs"
    echo "  vl ssh <name>                : SSH into VM"
    echo "  vl console <name>            : Attach to console"
    echo "  vl status                    : Show running VMs"
    echo ""
    echo "Additional useful commands:"
    echo "  vl storage_dir                     : Show current storage directory"
    echo "  vl distro_list                     : List locally available distro images"
    echo "  $(basename $0) --list-online       : List online available distro images"
    echo "  vl start <distro>                  : Start specific VM"
    echo "  vl stop <distro>                   : Stop specific VM"
    echo "  vl ssh <distro>                    : SSH into specific VM"
    echo "=============================="
    echo "To list available images online:"
    echo "  $(basename $0) --list-online"
}

# -------------------------------
# main
# -------------------------------
if [ "$1" == "--list-online" ]; then
    list_online_distros
    exit 0
fi

install_packages
check_libvirt_group
install_virt_lightning
prepare_user_dir
fix_permissions
main_menu

