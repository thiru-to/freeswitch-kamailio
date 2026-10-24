#!/usr/bin/env bash
#
# Install FreeSWITCH from source on Debian 13 (trixie) or Ubuntu 24.04 (noble).
#
# Usage:  sudo ./install-freeswitch.sh
#
# Tunables (override via environment):
#   PREFIX          install prefix                  (default /usr/local/freeswitch)
#   JOBS            parallel build jobs             (default nproc)
#   SRC_DIR         where sources are cloned        (default /usr/src)
#   FS_BRANCH       FreeSWITCH branch/tag           (default v1.11, the stable release branch; master is dev)
#   INSTALL_SOUNDS  1 to fetch sounds + music       (default 1)

set -euo pipefail

PREFIX="${PREFIX:-/usr/local/freeswitch}"
JOBS="${JOBS:-$(nproc)}"
SRC_DIR="${SRC_DIR:-/usr/src}"
FS_BRANCH="${FS_BRANCH:-v1.11}"
INSTALL_SOUNDS="${INSTALL_SOUNDS:-1}"

export DEBIAN_FRONTEND=noninteractive
# sofia-sip and spandsp install to /usr/local; make sure FreeSWITCH's configure finds them.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

log() { printf '\n=== %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root. Try: sudo $0" >&2
    exit 1
fi

# Clone if absent, otherwise fetch; then pin to a ref if one was given.
# Keeps the script re-runnable instead of dying on "directory already exists".
clone_or_update() {
    local url="$1" dir="$2" ref="${3:-}"
    if [ -d "$dir/.git" ]; then
        log "Updating $(basename "$dir")"
        git -C "$dir" fetch --tags --prune origin
    else
        log "Cloning $(basename "$dir")"
        git clone "$url" "$dir"
    fi
    # A bare fetch never moves the working tree, so a re-run would rebuild stale code.
    if [ -n "$ref" ]; then
        # Remote branch: -B resets a stale local branch to the fetched tip. Tag: plain checkout.
        if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$ref" >/dev/null; then
            git -C "$dir" checkout -B "$ref" "origin/$ref"
        else
            git -C "$dir" checkout "$ref"
        fi
    else
        git -C "$dir" pull --ff-only
    fi
}

### Update the system
log "Updating system packages"
apt-get -y update
# noninteractive alone doesn't answer dpkg conffile prompts; keep existing configs.
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade

### Install the pre-requisite dependencies.
# libjpeg-dev / libtiff-dev / libncurses-dev are the portable names: the versioned
# Debian spellings (libjpeg62-turbo-dev, libtiff5-dev, libncurses5-dev) are either
# absent or transitional across trixie and noble.
log "Installing build dependencies"
apt-get install -y \
    build-essential cmake automake autoconf libtool libtool-bin git \
    wget ca-certificates \
    pkg-config libssl-dev zlib1g-dev libncurses-dev \
    libgdbm-dev libdb-dev libcurl4-openssl-dev libtiff-dev \
    libjpeg-dev libsqlite3-dev libpcre2-dev \
    libspeexdsp-dev libspeex-dev libldns-dev libedit-dev \
    yasm libopus-dev libsndfile1-dev libavformat-dev \
    libswscale-dev liblua5.2-dev python3-dev \
    libpq-dev unixodbc-dev libxml2-dev libpng-dev uuid-dev libnode-dev

mkdir -p "$SRC_DIR"

### Install libks (FreeSWITCH 1.11 needs libks2, which is libks master).
# Installed into /usr rather than /usr/local so pkg-config finds it unambiguously.
clone_or_update https://github.com/signalwire/libks.git "$SRC_DIR/libks"
log "Building libks"
cmake -S "$SRC_DIR/libks" -B "$SRC_DIR/libks/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build "$SRC_DIR/libks/build" -j "$JOBS"
cmake --install "$SRC_DIR/libks/build"
ldconfig

### Install spandsp (the freeswitch fork; its default branch is the one FS wants).
clone_or_update https://github.com/freeswitch/spandsp.git "$SRC_DIR/spandsp"
log "Building spandsp"
cd "$SRC_DIR/spandsp"
./bootstrap.sh
./configure
make -j"$JOBS"
make install
ldconfig

### Install sofia-sip
clone_or_update https://github.com/freeswitch/sofia-sip.git "$SRC_DIR/sofia-sip"
log "Building sofia-sip"
cd "$SRC_DIR/sofia-sip"
./bootstrap.sh
./configure
make -j"$JOBS"
make install
ldconfig
ldconfig -p | grep sofia || { echo "sofia-sip did not land in the linker cache" >&2; exit 1; }

### Install FreeSWITCH
clone_or_update https://github.com/signalwire/freeswitch.git "$SRC_DIR/freeswitch" "$FS_BRANCH"
log "Building FreeSWITCH ($FS_BRANCH) into $PREFIX"
cd "$SRC_DIR/freeswitch"
./bootstrap.sh -j

# mod_signalwire needs a SignalWire token at runtime; not wanted for a self-hosted switch.
if [ -f modules.conf ]; then
    sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|' modules.conf
fi

# An explicit --prefix turns on the FHS layout ($PREFIX/var/run/freeswitch, $PREFIX/etc/freeswitch, ...);
# --disable-fhs keeps conf/log/db/run directly under $PREFIX, which the systemd unit below expects.
./configure --prefix="$PREFIX" --disable-fhs --disable-dependency-tracking
make -j"$JOBS"
make install

if [ "$INSTALL_SOUNDS" = "1" ]; then
    log "Installing sounds and music-on-hold"
    make cd-sounds-install cd-moh-install
fi

### Create the service account and lock down the tree
log "Creating freeswitch user and setting permissions"
getent group freeswitch >/dev/null || groupadd --system freeswitch
getent passwd freeswitch >/dev/null || adduser \
    --quiet --system \
    --home "$PREFIX" --no-create-home \
    --comment "FreeSWITCH open source softswitch" \
    --ingroup freeswitch \
    freeswitch

chown -R freeswitch:freeswitch "$PREFIX"
chmod -R ug=rwX,o= "$PREFIX"
chmod -R u=rwx,g=rx "$PREFIX"/bin/*

### systemd unit
# Paths point at $PREFIX (a source install keeps conf/log/db/run under the prefix),
# not at the /var/lib + /usr/bin layout the Debian *package* uses.
log "Installing systemd unit"
cat > /etc/systemd/system/freeswitch.service <<EOF
[Unit]
Description=FreeSWITCH
Wants=network-online.target
Requires=network.target local-fs.target
After=network.target network-online.target local-fs.target

[Service]
Type=forking
PIDFile=${PREFIX}/run/freeswitch.pid
Environment="DAEMON_OPTS=-nonat"
EnvironmentFile=-/etc/default/freeswitch
# Started as root so it can claim RT priority, then drops to freeswitch itself via -u/-g.
ExecStart=${PREFIX}/bin/freeswitch -u freeswitch -g freeswitch -ncwait \$DAEMON_OPTS
TimeoutStartSec=45s
TimeoutStopSec=45s
Restart=always
RestartSec=5
LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
LimitSTACK=250000
LimitRTPRIO=infinity
LimitRTTIME=infinity
IOSchedulingClass=realtime
IOSchedulingPriority=2
CPUSchedulingPolicy=rr
CPUSchedulingPriority=89
UMask=0007
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable freeswitch
# restart, not start: on a re-run the old binary would otherwise keep running.
systemctl restart freeswitch

log "Done. Check status with: systemctl status freeswitch"
log "Connect to the CLI with: ${PREFIX}/bin/fs_cli"
