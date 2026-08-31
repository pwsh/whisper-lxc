#!/usr/bin/env bash
# create-lxc.sh — create the unprivileged Debian 13 LXC that runs the standalone
# "whisper" speech-to-text appliance (OpenVINO Model Server on an Intel iGPU + NPU).
#
# Run as root ON the Proxmox VE host:
#
#     ssh proxmox bash -s < create-lxc.sh                     # all defaults, DHCP
#     VMID=301 IP=192.168.1.50/24 GW=192.168.1.1 ssh proxmox bash -s < create-lxc.sh
#     sudo ./create-lxc.sh --vmid 301 --ip dhcp               # on the host itself
#
# It does the host half only: the container, its devices and its network.  The
# software half is setup-inside.sh, which this script prints instructions for
# (and runs for you when it can find it next to itself).
#
# See README.md for the full walkthrough.
set -Eeuo pipefail

# Both guarded: this script is routinely fed to bash on stdin (`ssh proxmox bash -s < …`),
# where BASH_SOURCE is empty and $0 is "bash" — and `set -u` makes an unguarded read fatal.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '')
SCRIPT_NAME=${0##*/}
[[ $SCRIPT_NAME == bash || -z $SCRIPT_NAME ]] && SCRIPT_NAME=create-lxc.sh

# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
fi

CURRENT_STEP='startup'
step()  { CURRENT_STEP=$1; printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$1" >&2; }
info()  { printf '%s  ·%s %s\n'   "$C_DIM"  "$C_RESET" "$*" >&2; }
ok()    { printf '%s  ✓%s %s\n'   "$C_OK"   "$C_RESET" "$*" >&2; }
warn()  { printf '%swarn:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

CT_CREATED=0
on_err() {
    local rc=$? line=$1
    printf '%serror:%s failed at line %s during step: %s (exit %s)\n' \
        "$C_ERR" "$C_RESET" "$line" "$CURRENT_STEP" "$rc" >&2
    if [[ $CT_CREATED == 1 ]]; then
        printf '%swarn:%s container %s was created and is NOT being removed.\n' "$C_WARN" "$C_RESET" "$VMID" >&2
        printf '      inspect:  pct enter %s\n' "$VMID" >&2
        printf '      destroy:  pct stop %s && pct destroy %s\n' "$VMID" "$VMID" >&2
    fi
    exit "$rc"
}
trap 'on_err $LINENO' ERR

# --------------------------------------------------------------------------- #
# configuration — every knob is an environment variable with a matching flag
# --------------------------------------------------------------------------- #
VMID=${VMID:-301}
# HOSTNAME is a variable bash sets in every shell, so ${HOSTNAME:-whisper} would
# silently name the container after the Proxmox node.  Only an *exported* value
# (which is what `VAR=x ssh host bash -s` and `VAR=x ./script` both produce) counts.
if [[ -n $(printenv HOSTNAME 2>/dev/null || true) ]]; then
    CT_HOSTNAME=$HOSTNAME
else
    CT_HOSTNAME=whisper
fi
IP=${IP:-dhcp}
GW=${GW:-192.168.1.1}
# 8 cores and 12 GB are *measured* minimums, not round numbers.  Whisper's front
# half — mp3 decode, the mel spectrogram, tokenisation — runs on the CPU on the
# way to the accelerator, and it is the binding constraint on the GPU path: the
# same corpus ran at 9.8x real time with 4 cores and 16.0x with 8, while the NPU
# path (12.8x) did not move.  8 GB also puts a four-servable config into swap.
# `--cores` is a ceiling, not a reservation, so this shares the node happily.
CORES=${CORES:-8}
MEMORY=${MEMORY:-12288}
SWAP=${SWAP:-2048}
DISK=${DISK:-32}
STORAGE=${STORAGE:-local-lvm}
BRIDGE=${BRIDGE:-vmbr0}
VLAN=${VLAN:-}
TEMPLATE=${TEMPLATE:-local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst}
GPU=${GPU:-1}
NPU=${NPU:-1}
GPU_DEV=${GPU_DEV:-/dev/dri/renderD128}
NPU_DEV=${NPU_DEV:-/dev/accel/accel0}
# The gid of `render` *inside* a Debian 13 container (992), not the node's (993).
# pct creates the device node in the guest owned by this gid; docker's --group-add
# then has to match it.  Verify with: pct exec $VMID -- getent group render
RENDER_GID=${RENDER_GID:-992}
SSH_PUBKEY=${SSH_PUBKEY:-}
CT_PASSWORD=${CT_PASSWORD:-}
TIMEZONE=${TIMEZONE:-Etc/UTC}
FORCE=${FORCE:-0}
NO_SETUP=${NO_SETUP:-0}
START_ONLY=${START_ONLY:-0}

usage() {
    cat <<EOF
${SCRIPT_NAME} — create the unprivileged Debian 13 LXC for the standalone whisper
(OpenVINO Model Server) speech-to-text appliance, with the Intel iGPU and NPU
device nodes passed into it.

USAGE
  sudo ./${SCRIPT_NAME} [options]
  VMID=301 IP=dhcp ssh proxmox bash -s < ${SCRIPT_NAME}

Every option also reads the environment variable named beside it.

CONTAINER
  --vmid N          Container ID                        (VMID, ${VMID})
  --hostname NAME   Container hostname                  (HOSTNAME, ${CT_HOSTNAME})
  --cores N         vCPU cores                          (CORES, ${CORES})
  --memory MB       RAM in MB                           (MEMORY, ${MEMORY})
  --swap MB         Swap in MB                          (SWAP, ${SWAP})
  --disk GB         Root disk in GB                     (DISK, ${DISK})
  --storage NAME    Storage for the rootfs              (STORAGE, ${STORAGE})
  --template REF    CT template                         (TEMPLATE, ${TEMPLATE})
  --timezone ZONE   Container timezone                  (TIMEZONE, ${TIMEZONE})

NETWORK
  --ip ADDR         'dhcp' or CIDR (192.168.1.50/24)       (IP, ${IP})
  --gw ADDR         Gateway, required with a static IP  (GW, ${GW})
  --bridge NAME     Linux bridge                        (BRIDGE, ${BRIDGE})
  --vlan TAG        VLAN tag for the NIC                (VLAN, none)

ACCELERATORS
  --gpu 0|1         Pass ${GPU_DEV}       (GPU, ${GPU})
  --npu 0|1         Pass ${NPU_DEV}         (NPU, ${NPU})
  --render-gid N    render gid INSIDE the guest         (RENDER_GID, ${RENDER_GID})

ACCESS
  --ssh-pubkey X    Public key, as a file path or the key text itself
                    (SSH_PUBKEY; default ~/.ssh/authorized_keys if present)
  --password PASS   root password                       (CT_PASSWORD, generated)

FLOW CONTROL
  --force           Reuse/replace an existing VMID      (FORCE, ${FORCE})
  --start-only      Skip 'pct create', just start VMID and run the setup
  --no-setup        Create and start only; do not run setup-inside.sh
  -h, --help        This text.

NOTES
  The host kernel must already have the drivers up — this container can only be
  given a device the node has: 'xe' or 'i915' for ${GPU_DEV} and
  'intel_vpu' for ${NPU_DEV}.  A container cannot load them.
EOF
}

need_value() { [[ $# -ge 2 && -n ${2:-} ]] || die "option $1 requires a value"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)        need_value "$@"; VMID=$2; shift 2 ;;
        --hostname)    need_value "$@"; CT_HOSTNAME=$2; shift 2 ;;
        --cores)       need_value "$@"; CORES=$2; shift 2 ;;
        --memory)      need_value "$@"; MEMORY=$2; shift 2 ;;
        --swap)        need_value "$@"; SWAP=$2; shift 2 ;;
        --disk)        need_value "$@"; DISK=$2; shift 2 ;;
        --storage)     need_value "$@"; STORAGE=$2; shift 2 ;;
        --template)    need_value "$@"; TEMPLATE=$2; shift 2 ;;
        --timezone)    need_value "$@"; TIMEZONE=$2; shift 2 ;;
        --ip)          need_value "$@"; IP=$2; shift 2 ;;
        --gw)          need_value "$@"; GW=$2; shift 2 ;;
        --bridge)      need_value "$@"; BRIDGE=$2; shift 2 ;;
        --vlan)        need_value "$@"; VLAN=$2; shift 2 ;;
        --gpu)         need_value "$@"; GPU=$2; shift 2 ;;
        --npu)         need_value "$@"; NPU=$2; shift 2 ;;
        --render-gid)  need_value "$@"; RENDER_GID=$2; shift 2 ;;
        --ssh-pubkey)  need_value "$@"; SSH_PUBKEY=$2; shift 2 ;;
        --password)    need_value "$@"; CT_PASSWORD=$2; shift 2 ;;
        --force)       FORCE=1; shift ;;
        --start-only)  START_ONLY=1; shift ;;
        --no-setup)    NO_SETUP=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "unknown option: $1" ;;
    esac
done

# --------------------------------------------------------------------------- #
# validation
# --------------------------------------------------------------------------- #
step 'validating the environment'
[[ $EUID -eq 0 ]] || die 'must run as root on the Proxmox VE host'
command -v pct >/dev/null || die "'pct' not found — this is not a Proxmox VE host"
[[ $VMID =~ ^[0-9]+$ ]] || die "--vmid must be a number, got '$VMID'"

if [[ $IP != dhcp ]]; then
    [[ $IP == */* ]] || die "--ip must be 'dhcp' or CIDR notation (e.g. 192.168.1.50/24)"
    [[ -n $GW ]] || die '--gw is required when --ip is a static address'
fi

EXISTS=0
if pct status "$VMID" >/dev/null 2>&1; then EXISTS=1; fi
if [[ $EXISTS == 1 && $START_ONLY == 0 && $FORCE == 0 ]]; then
    die "VMID $VMID already exists. Re-run with FORCE=1 to destroy and recreate it, or START_ONLY=1 to reuse it."
fi
if [[ $EXISTS == 0 && $START_ONLY == 1 ]]; then die "START_ONLY=1 but VMID $VMID does not exist"; fi
ok "PVE $(pveversion --verbose 2>/dev/null | awk 'NR==1{print $2}' || echo '?'), VMID $VMID"

# The devices have to exist on the NODE before pct can hand them over.
DEV_ARGS=()
DEV_N=0
if [[ $GPU == 1 ]]; then
    [[ -e $GPU_DEV ]] || die "GPU=1 but $GPU_DEV does not exist on this node — is the 'xe'/'i915' module loaded? (lsmod | grep -E 'xe|i915')"
    DEV_ARGS+=(--dev${DEV_N} "${GPU_DEV},gid=${RENDER_GID},mode=0660"); DEV_N=$((DEV_N + 1))
    ok "GPU  $GPU_DEV  -> dev$((DEV_N - 1)) gid=$RENDER_GID"
fi
if [[ $NPU == 1 ]]; then
    [[ -e $NPU_DEV ]] || die "NPU=1 but $NPU_DEV does not exist on this node — is 'intel_vpu' loaded? (lsmod | grep intel_vpu). Re-run with NPU=0 on a machine without one."
    DEV_ARGS+=(--dev${DEV_N} "${NPU_DEV},gid=${RENDER_GID},mode=0660"); DEV_N=$((DEV_N + 1))
    ok "NPU  $NPU_DEV  -> dev$((DEV_N - 1)) gid=$RENDER_GID"
fi
(( DEV_N > 0 )) || warn 'neither GPU nor NPU is being passed in — OVMS will fall back to the CPU'

# ssh key: accept a path or the key text, because `ssh host bash -s` cannot ship a file.
KEYFILE=''
TMPKEY=''
cleanup() { [[ -n $TMPKEY && -f $TMPKEY ]] && rm -f -- "$TMPKEY"; return 0; }
trap cleanup EXIT
if [[ -z $SSH_PUBKEY && -f /root/.ssh/authorized_keys ]]; then
    SSH_PUBKEY=/root/.ssh/authorized_keys
    info 'using /root/.ssh/authorized_keys as the guest root key'
fi
if [[ -n $SSH_PUBKEY ]]; then
    if [[ -f $SSH_PUBKEY ]]; then
        KEYFILE=$SSH_PUBKEY
    elif [[ $SSH_PUBKEY == ssh-* || $SSH_PUBKEY == ecdsa-* ]]; then
        TMPKEY=$(mktemp); printf '%s\n' "$SSH_PUBKEY" >"$TMPKEY"; KEYFILE=$TMPKEY
    else
        die "--ssh-pubkey is neither a readable file nor a public key ('ssh-…'): $SSH_PUBKEY"
    fi
fi
[[ -n $KEYFILE ]] || warn 'no ssh key — you will only be able to get in with `pct enter`'

if [[ -z $CT_PASSWORD ]]; then
    CT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
    PASSWORD_GENERATED=1
else
    PASSWORD_GENERATED=0
fi

# --------------------------------------------------------------------------- #
# create
# --------------------------------------------------------------------------- #
if [[ $EXISTS == 1 && $FORCE == 1 && $START_ONLY == 0 ]]; then
    step "destroying the existing container $VMID (FORCE=1)"
    pct stop "$VMID" >/dev/null 2>&1 || true
    pct destroy "$VMID"
    ok "destroyed $VMID"
    EXISTS=0
fi

if [[ $EXISTS == 0 ]]; then
    step 'creating the container'
    net="name=eth0,bridge=${BRIDGE}"
    if [[ $IP == dhcp ]]; then net+=',ip=dhcp'; else net+=",ip=${IP},gw=${GW}"; fi
    [[ -n $VLAN ]] && net+=",tag=${VLAN}"

    # The commas in --features are one pct argument, not three.
    # shellcheck disable=SC2054
    args=(
        "$VMID" "$TEMPLATE"
        --unprivileged 1
        --features nesting=1
        --ostype debian
        --onboot 1
        --cores "$CORES"
        --memory "$MEMORY"
        --swap "$SWAP"
        --rootfs "${STORAGE}:${DISK}"
        --net0 "$net"
        --hostname "$CT_HOSTNAME"
        --timezone "$TIMEZONE"
        --description "whisper — OpenVINO Model Server speech-to-text appliance (whisper-lxc)"
    )
    args+=("${DEV_ARGS[@]}")
    [[ -n $KEYFILE ]] && args+=(--ssh-public-keys "$KEYFILE")

    info "pct create $VMID $TEMPLATE (${CORES} cores, ${MEMORY} MB, ${DISK} GB on ${STORAGE})"
    pct create "${args[@]}"
    CT_CREATED=1
    ok "container $VMID created"
fi

# --------------------------------------------------------------------------- #
# start + wait
# --------------------------------------------------------------------------- #
step 'starting the container'
if [[ $(pct status "$VMID") == 'status: running' ]]; then
    info 'already running'
else
    pct start "$VMID"
fi

deadline=$((SECONDS + 180))
info 'waiting for the container to finish booting'
while (( SECONDS < deadline )); do
    pct exec "$VMID" -- test -x /bin/systemctl >/dev/null 2>&1 && break
    sleep 2
done
pct exec "$VMID" -- systemctl is-system-running --wait >/dev/null 2>&1 || true

info 'waiting for network + DNS'
netok=0
while (( SECONDS < deadline )); do
    if pct exec "$VMID" -- getent hosts download.docker.com >/dev/null 2>&1; then netok=1; break; fi
    sleep 3
done
(( netok == 1 )) || die "no working network/DNS inside $VMID after 180 s — check --ip/--gw/--bridge"
ok 'container is up'

# `pct exec` needs a *running* container, so the password is set here rather than
# beside `pct create`.  On stdin so it never reaches the node's process list.
step 'setting the root password'
printf 'root:%s\n' "$CT_PASSWORD" | pct exec "$VMID" -- chpasswd
ok 'root password set' 

# --------------------------------------------------------------------------- #
# verify the devices landed, in the guest, with the gid we claimed
# --------------------------------------------------------------------------- #
step 'verifying the accelerators inside the guest'
GUEST_RENDER_GID=$(pct exec "$VMID" -- getent group render 2>/dev/null | cut -d: -f3 || true)
if [[ -n $GUEST_RENDER_GID && $GUEST_RENDER_GID != "$RENDER_GID" ]]; then
    warn "the guest's 'render' group is gid $GUEST_RENDER_GID but the devices were passed with gid=$RENDER_GID."
    warn "fix with: pct set $VMID --dev0 ${GPU_DEV},gid=${GUEST_RENDER_GID},mode=0660 …  (and RENDER_GID=$GUEST_RENDER_GID in the guest's .env)"
else
    ok "guest 'render' group is gid ${GUEST_RENDER_GID:-<absent>}, matching the device gid"
fi
pct exec "$VMID" -- sh -c 'ls -l /dev/dri /dev/accel 2>/dev/null || true' >&2 || true

# --------------------------------------------------------------------------- #
# report + hand off
# --------------------------------------------------------------------------- #
step 'address'
CT_IP=''
for _ in $(seq 1 20); do
    CT_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -n $CT_IP ]] && break
    sleep 2
done
[[ -n $CT_IP ]] || warn 'could not read the container IP; try `pct exec '"$VMID"' -- hostname -I`'
ok "container $VMID ($CT_HOSTNAME) is at ${CT_IP:-unknown}"

if [[ $NO_SETUP == 0 && -n $SCRIPT_DIR && -f "$SCRIPT_DIR/setup-inside.sh" ]]; then
    step 'running setup-inside.sh in the guest'
    pct push "$VMID" "$SCRIPT_DIR/setup-inside.sh" /root/setup-inside.sh --perms 755
    for f in compose.yaml compose.gpu-only.yaml prepare-models.sh .env.example; do
        [[ -f "$SCRIPT_DIR/$f" ]] && pct push "$VMID" "$SCRIPT_DIR/$f" "/root/whisper-kit-$f"
    done
    pct exec "$VMID" -- env RENDER_GID="${GUEST_RENDER_GID:-$RENDER_GID}" NPU="$NPU" GPU="$GPU" \
        KIT_DIR=/root bash /root/setup-inside.sh
else
    cat >&2 <<EOF

${C_INFO}==>${C_RESET} next: install the stack inside it

    # from the machine holding this kit
    for f in setup-inside.sh compose.yaml compose.gpu-only.yaml prepare-models.sh .env.example; do
        scp \$f root@${CT_IP:-<ip>}:/root/whisper-kit-\$f
    done
    ssh root@${CT_IP:-<ip>} 'mv /root/whisper-kit-setup-inside.sh /root/setup-inside.sh && \\
        RENDER_GID=${GUEST_RENDER_GID:-$RENDER_GID} bash /root/setup-inside.sh'

    # or, straight from the PVE host
    pct push $VMID setup-inside.sh /root/setup-inside.sh --perms 755
    pct exec $VMID -- bash /root/setup-inside.sh
EOF
fi

cat >&2 <<EOF

${C_OK}==>${C_RESET} container $VMID '$CT_HOSTNAME'
    address       : ${CT_IP:-unknown}${IP:+  (${IP})}
    root password : $CT_PASSWORD$( [[ $PASSWORD_GENERATED == 1 ]] && printf '   (generated)' )
    devices       : $( [[ $GPU == 1 ]] && printf '%s ' "$GPU_DEV" )$( [[ $NPU == 1 ]] && printf '%s' "$NPU_DEV" )
    shell         : pct enter $VMID     |     ssh root@${CT_IP:-<ip>}
    logs          : pct exec $VMID -- docker compose -f /opt/whisper/compose.yaml logs -f

    DHCP gave it ${CT_IP:-that address} — reserve it in the router, or recreate with
    IP=${CT_IP:-192.168.1.x}/24 GW=$GW so it never moves.
EOF
