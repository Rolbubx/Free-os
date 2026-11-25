#!/bin/bash
# GCE startup script for the FreeOS build VM. Runs as root on every boot.
# First boot: formats the data disk, installs AOSP build deps, registers the
# GitHub Actions runner. Every boot: mounts the disk, enables swap, arms the
# idle auto-poweroff.
set -euxo pipefail

md() {
  curl -fs -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true
}

BUILD_USER=builder
DATA=/aosp
DISK=/dev/disk/by-id/google-aosp
RUNNER_DIR=/opt/actions-runner

id "$BUILD_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$BUILD_USER"

# --- data disk --------------------------------------------------------------
blkid "$DISK" >/dev/null 2>&1 ||
  mkfs.ext4 -m 0 -L aosp -E lazy_itable_init=0,lazy_journal_init=0,discard "$DISK"
mkdir -p "$DATA"
mountpoint -q "$DATA" || mount -o discard,defaults,noatime "$DISK" "$DATA"
grep -q 'LABEL=aosp' /etc/fstab ||
  echo 'LABEL=aosp /aosp ext4 discard,defaults,noatime,nofail 0 2' >> /etc/fstab
mkdir -p "$DATA"/{src,ccache,_work}
chown "$BUILD_USER:" "$DATA" "$DATA"/{src,ccache,_work}

if [ ! -f "$DATA/swapfile" ]; then
  fallocate -l 16G "$DATA/swapfile"
  chmod 600 "$DATA/swapfile"
  mkswap "$DATA/swapfile"
fi
swapon --show | grep -q "$DATA/swapfile" || swapon "$DATA/swapfile"

# --- idle auto-poweroff (cost guard) ----------------------------------------
cat > /usr/local/sbin/freeos-idle-stop <<'EOF'
#!/bin/bash
# Powers the VM off after IDLE_LIMIT minutes without a running CI job.
# Create /aosp/.keep-awake to disable (e.g. while working over SSH).
IDLE_LIMIT=30
STATE=/run/freeos-idle-since
[ -e /aosp/.keep-awake ] && exit 0
if pgrep -f Runner.Worker >/dev/null; then rm -f "$STATE"; exit 0; fi
now=$(date +%s)
[ -f "$STATE" ] || echo "$now" > "$STATE"
if (( now - $(cat "$STATE") >= IDLE_LIMIT * 60 )); then
  logger "freeos: idle for ${IDLE_LIMIT} min, powering off"
  systemctl poweroff
fi
EOF
chmod 755 /usr/local/sbin/freeos-idle-stop
cat > /etc/systemd/system/freeos-idle-stop.service <<'EOF'
[Unit]
Description=Power off FreeOS build VM when idle
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/freeos-idle-stop
EOF
cat > /etc/systemd/system/freeos-idle-stop.timer <<'EOF'
[Unit]
Description=Check FreeOS build VM idleness every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now freeos-idle-stop.timer

# --- build dependencies (first boot) -----------------------------------------
if [ ! -f /var/lib/freeos-deps-done ]; then
  # unattended-upgrades holds the dpkg lock right after first boot
  apt-get -o DPkg::Lock::Timeout=900 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y \
    git-core gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 \
    x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc \
    unzip fontconfig python3 python-is-python3 libncurses5 ccache rsync zstd jq
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
  chmod a+rx /usr/local/bin/repo
  sudo -u "$BUILD_USER" git config --global user.name "FreeOS CI"
  sudo -u "$BUILD_USER" git config --global user.email "ci@freeos.invalid"
  sudo -u "$BUILD_USER" git config --global color.ui false
  touch /var/lib/freeos-deps-done
fi

# --- GitHub Actions runner (first boot, or after a token refresh) -------------
set +x   # don't echo the registration token into the serial console log
if [ ! -f "$RUNNER_DIR/.runner" ]; then
  REPO=$(md gh-repo)
  TOKEN=$(md gh-runner-token)
  if [ -z "$REPO" ] || [ -z "$TOKEN" ]; then
    echo "gh-repo / gh-runner-token metadata missing; runner not registered" >&2
    exit 0
  fi
  VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
  mkdir -p "$RUNNER_DIR"
  curl -fsSL "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-linux-x64-$VERSION.tar.gz" |
    tar -xz -C "$RUNNER_DIR"
  "$RUNNER_DIR/bin/installdependencies.sh"
  chown -R "$BUILD_USER:" "$RUNNER_DIR"
  sudo -u "$BUILD_USER" "$RUNNER_DIR/config.sh" --unattended --replace \
    --url "https://github.com/$REPO" --token "$TOKEN" \
    --name "$(hostname)" --labels freeos-aosp --work "$DATA/_work"
  (cd "$RUNNER_DIR" && ./svc.sh install "$BUILD_USER" && ./svc.sh start)
fi
