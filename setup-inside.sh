#!/usr/bin/env bash
# setup-inside.sh — install Docker CE and bring up the whisper (OpenVINO Model
# Server) speech-to-text appliance.
#
# Designed to run as root INSIDE the Debian 13 LXC that create-lxc.sh builds, but
# it works on any Debian 12/13 host, VM or container that can run Docker and has
# an Intel render node.  For an LXC that means `features nesting=1` and the device
# nodes already passed in with the guest's own render gid.
#
#     bash setup-inside.sh                 # kit files sit next to this script
#     KIT_DIR=/root bash setup-inside.sh   # …or in /root, as create-lxc.sh pushes them
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '/root')
SCRIPT_NAME=${0##*/}
[[ $SCRIPT_NAME == bash || -z $SCRIPT_NAME ]] && SCRIPT_NAME=setup-inside.sh

# A fresh CT has only the C/C.UTF-8 locales; whatever LANG an ssh/pct session
# forwards is not generated yet and makes perl and apt complain on every call.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset LANGUAGE

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
on_err() {
    local rc=$? line=$1
    printf '%serror:%s failed at line %s during step: %s (exit %s)\n' \
        "$C_ERR" "$C_RESET" "$line" "$CURRENT_STEP" "$rc" >&2
    exit "$rc"
}
trap 'on_err $LINENO' ERR

# --------------------------------------------------------------------------- #
# configuration
# --------------------------------------------------------------------------- #
PROJECT_DIR=${PROJECT_DIR:-/opt/whisper}
KIT_DIR=${KIT_DIR:-$SCRIPT_DIR}
GPU=${GPU:-1}
NPU=${NPU:-1}
GPU_DEV=${GPU_DEV:-/dev/dri/renderD128}
NPU_DEV=${NPU_DEV:-/dev/accel/accel0}
RENDER_GID=${RENDER_GID:-}
PORT=${PORT:-8000}
OVMS_IMAGE_TAG=${OVMS_IMAGE_TAG:-weekly}
MODELS=${MODELS:-OpenVINO/whisper-large-v3-turbo-fp16-ov,OpenVINO/whisper-medium-fp16-ov}
DEVICES=${DEVICES:-}
DEFAULT_MODEL=${DEFAULT_MODEL:-whisper-large-v3-turbo}
TZ_=${TZ:-Etc/UTC}
NO_MODELS=${NO_MODELS:-0}
NO_UP=${NO_UP:-0}

usage() {
    cat <<EOF
${SCRIPT_NAME} — install Docker CE and start the whisper (OVMS) STT appliance.

USAGE
  bash ${SCRIPT_NAME} [options]

Every option also reads the environment variable named beside it.

  --project-dir PATH  Where the stack lives      (PROJECT_DIR, ${PROJECT_DIR})
  --kit-dir PATH      Where compose.yaml, prepare-models.sh and .env.example are
                      (KIT_DIR, ${KIT_DIR}); create-lxc.sh pushes them to /root
                      with a 'whisper-kit-' prefix, which is also looked for.
  --models LIST       Repos to serve            (MODELS, ${MODELS})
  --devices LIST      GPU,NPU,CPU               (DEVICES, from --gpu/--npu)
  --default-model X   Target of the whisper-gpu / whisper-npu aliases
                                                (DEFAULT_MODEL, ${DEFAULT_MODEL})
  --port N            Published REST port       (PORT, ${PORT})
  --image-tag TAG     openvino/model_server tag (OVMS_IMAGE_TAG, ${OVMS_IMAGE_TAG})
  --render-gid N      render gid in this guest  (RENDER_GID, auto-detected)
  --gpu 0|1           Expect ${GPU_DEV}   (GPU, ${GPU})
  --npu 0|1           Expect ${NPU_DEV}     (NPU, ${NPU})
  --no-models         Skip prepare-models.sh    (NO_MODELS=1)
  --no-up             Skip 'docker compose up'  (NO_UP=1)
  -h, --help          This text.
EOF
}

need_value() { [[ $# -ge 2 && -n ${2:-} ]] || die "option $1 requires a value"; }
while [[ $# -gt 0 ]]; do
    case $1 in
        --project-dir)   need_value "$@"; PROJECT_DIR=$2; shift 2 ;;
        --kit-dir)       need_value "$@"; KIT_DIR=$2; shift 2 ;;
        --models)        need_value "$@"; MODELS=$2; shift 2 ;;
        --devices)       need_value "$@"; DEVICES=$2; shift 2 ;;
        --default-model) need_value "$@"; DEFAULT_MODEL=$2; shift 2 ;;
        --port)          need_value "$@"; PORT=$2; shift 2 ;;
        --image-tag)     need_value "$@"; OVMS_IMAGE_TAG=$2; shift 2 ;;
        --render-gid)    need_value "$@"; RENDER_GID=$2; shift 2 ;;
        --gpu)           need_value "$@"; GPU=$2; shift 2 ;;
        --npu)           need_value "$@"; NPU=$2; shift 2 ;;
        --no-models)     NO_MODELS=1; shift ;;
        --no-up)         NO_UP=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die 'must run as root'

# --------------------------------------------------------------------------- #
# 1. the accelerators — checked BEFORE anything is installed, because a missing
#    device node is a host-side mistake and no amount of guest setup fixes it.
# --------------------------------------------------------------------------- #
check_devices() {
    step 'checking the accelerators'
    local detected
    detected=$(getent group render 2>/dev/null | cut -d: -f3 || true)
    if [[ -z $RENDER_GID ]]; then
        [[ -n $detected ]] || die "no 'render' group in this guest and no --render-gid given"
        RENDER_GID=$detected
        info "render group is gid $RENDER_GID (auto-detected)"
    elif [[ -n $detected && $detected != "$RENDER_GID" ]]; then
        warn "--render-gid $RENDER_GID but this guest's render group is gid $detected"
    fi

    local dev gid_of missing=0
    for dev in $( [[ $GPU == 1 ]] && echo "$GPU_DEV"; [[ $NPU == 1 ]] && echo "$NPU_DEV" ); do
        if [[ ! -e $dev ]]; then
            warn "$dev is missing"
            missing=1
            continue
        fi
        gid_of=$(stat -c '%g' "$dev")
        if [[ $gid_of != "$RENDER_GID" ]]; then
            warn "$dev is group $gid_of ($(stat -c '%G' "$dev")), not $RENDER_GID — OVMS will not be able to open it"
            warn "fix on the Proxmox node: pct set <VMID> --devN ${dev},gid=${RENDER_GID},mode=0660"
        else
            ok "$dev  $(stat -c '%A %U:%G' "$dev")"
        fi
    done
    if (( missing )); then
        cat >&2 <<EOF
error: a device node this guest was told to use does not exist.

  It has to be created by the HOST, not here.  On the Proxmox node:
      lsmod | grep -E 'xe|i915'      # the GPU driver, for ${GPU_DEV}
      lsmod | grep intel_vpu         # the NPU driver, for ${NPU_DEV}
      pct set <VMID> --dev0 ${GPU_DEV},gid=${RENDER_GID},mode=0660 \\
                     --dev1 ${NPU_DEV},gid=${RENDER_GID},mode=0660
      pct reboot <VMID>

  On a machine that genuinely has no NPU, re-run with --npu 0.
EOF
        die 'missing accelerator device node'
    fi
}

# --------------------------------------------------------------------------- #
# 2. Docker CE
# --------------------------------------------------------------------------- #
install_docker() {
    step 'installing Docker CE'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl jq >/dev/null

    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        info "docker already installed: $(docker --version)"
    else
        local codename=''
        # shellcheck disable=SC1091
        [[ -r /etc/os-release ]] && codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
        [[ -n $codename ]] || die 'could not determine the Debian codename from /etc/os-release'

        # Only fall back to bookworm when download.docker.com really has no suite for
        # this release (404).  A DNS or routing failure must NOT be read as a missing
        # suite — that installs bookworm packages on trixie and then blames Docker.
        local url="https://download.docker.com/linux/debian/dists/${codename}/Release" code
        code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 40 \
                    --retry 3 --retry-delay 3 --retry-all-errors "$url" 2>/dev/null || true)
        case ${code:-000} in
            200) ;;
            404) warn "download.docker.com has no '${codename}' suite yet — using the bookworm packages"
                 codename=bookworm ;;
            *)   die "cannot reach ${url} from inside this guest (HTTP ${code:-000}). Check DNS and the default route." ;;
        esac
        info "using the Docker apt suite '${codename}'"

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
            "$(dpkg --print-architecture)" "$codename" >/etc/apt/sources.list.d/docker.list
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
        ok "installed $(docker --version)"
    fi
    systemctl enable --now docker >/dev/null 2>&1
    ok 'docker.service enabled and running'
}

# An unprivileged LXC on ZFS makes Docker fall back to the 'vfs' storage driver,
# which copies the whole image on every layer — a 3 GB OVMS image becomes minutes
# and gigabytes.  fuse-overlayfs is the supported way out.  On ext4-backed rootfs
# (local-lvm, the default here) overlay2 works and this is a no-op.
fix_storage_driver() {
    step 'checking the Docker storage driver'
    local driver
    driver=$(docker info --format '{{.Driver}}' 2>/dev/null || printf unknown)
    if [[ $driver != vfs ]]; then ok "storage driver: $driver"; return; fi
    warn "storage driver is 'vfs' — switching to fuse-overlayfs"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fuse-overlayfs >/dev/null
    mkdir -p /etc/docker
    if [[ -s /etc/docker/daemon.json ]] && command -v jq >/dev/null; then
        jq '. + {"storage-driver":"fuse-overlayfs"}' /etc/docker/daemon.json >/etc/docker/daemon.json.new
        mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
        printf '{\n  "storage-driver": "fuse-overlayfs"\n}\n' >/etc/docker/daemon.json
    fi
    systemctl restart docker
    ok "storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null || printf unknown)"
}

# --------------------------------------------------------------------------- #
# 3. the stack
# --------------------------------------------------------------------------- #
kit_file() {
    # create-lxc.sh pushes the kit into /root with a 'whisper-kit-' prefix so it
    # cannot collide with anything already there; a hand copy leaves plain names.
    local name=$1
    for c in "$KIT_DIR/$name" "$KIT_DIR/whisper-kit-$name" "$SCRIPT_DIR/$name" "$SCRIPT_DIR/whisper-kit-$name"; do
        [[ -f $c ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

install_stack() {
    step "installing the stack into $PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    local name src
    for name in compose.yaml compose.gpu-only.yaml prepare-models.sh .env.example; do
        if src=$(kit_file "$name"); then
            install -m 0644 "$src" "$PROJECT_DIR/$name"
            info "$name"
        elif [[ $name == compose.gpu-only.yaml ]]; then
            warn "$name not found next to this script — GPU-only hosts will need it"
        else
            die "$name not found in $KIT_DIR or $SCRIPT_DIR — copy the whole deploy/whisper-lxc directory over"
        fi
    done
    [[ -f $PROJECT_DIR/prepare-models.sh ]] && chmod 0755 "$PROJECT_DIR/prepare-models.sh"
    ok "stack installed"
}

write_env() {
    step 'writing .env'
    if [[ -z $DEVICES ]]; then
        DEVICES=$( { [[ $GPU == 1 ]] && printf 'GPU,'; [[ $NPU == 1 ]] && printf 'NPU,'; } | sed 's/,$//' )
        [[ -n $DEVICES ]] || DEVICES=CPU
    fi
    if [[ -f $PROJECT_DIR/.env ]]; then
        cp "$PROJECT_DIR/.env" "$PROJECT_DIR/.env.bak"
        info 'existing .env kept as .env.bak'
    fi
    {
        printf '# generated by setup-inside.sh on %s — see .env.example for what each knob does\n' "$(date -Is)"
        printf 'MODELS=%s\n'         "$MODELS"
        printf 'DEVICES=%s\n'        "$DEVICES"
        printf 'DEFAULT_MODEL=%s\n'  "$DEFAULT_MODEL"
        printf 'OVMS_IMAGE_TAG=%s\n' "$OVMS_IMAGE_TAG"
        printf 'PORT=%s\n'           "$PORT"
        printf 'OVMS_LOG_LEVEL=%s\n' "${OVMS_LOG_LEVEL:-INFO}"
        printf 'RENDER_GID=%s\n'     "$RENDER_GID"
        printf 'GPU_DEV=%s\n'        "$GPU_DEV"
        printf 'NPU_DEV=%s\n'        "$NPU_DEV"
        printf 'TZ=%s\n'             "$TZ_"
        # `devices:` is replace-not-merge, so the override is how a host with no NPU
        # gets a service whose device list compose can actually satisfy.
        if [[ $NPU != 1 ]]; then
            printf 'COMPOSE_FILE=compose.yaml:compose.gpu-only.yaml\n'
        fi
    } >"$PROJECT_DIR/.env"
    chmod 0600 "$PROJECT_DIR/.env"
    ok "DEVICES=$DEVICES  RENDER_GID=$RENDER_GID  PORT=$PORT"
}

prepare_models() {
    if [[ $NO_MODELS == 1 ]]; then warn 'skipping prepare-models.sh (--no-models)'; return; fi
    step 'preparing the models (first run downloads several GB)'
    ( cd "$PROJECT_DIR" && bash prepare-models.sh )
    ok 'models prepared'
}

compose_up() {
    if [[ $NO_UP == 1 ]]; then warn "skipping 'docker compose up' (--no-up)"; return; fi
    step 'starting the server'
    ( cd "$PROJECT_DIR" && docker compose up -d )
    ok 'container started'
}

wait_for_api() {
    if [[ $NO_UP == 1 ]]; then return; fi
    step 'waiting for /v1/models'
    # OVMS binds the REST port and answers `{"data":[]}` within a second of start
    # and then compiles for minutes, so "did it answer" is the wrong question —
    # the right one is "does it list anything yet".
    local deadline=$((SECONDS + 900)) body=''
    while (( SECONDS < deadline )); do
        body=$(curl -sf --max-time 10 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)
        if [[ $body == *'"id"'* ]]; then
            ok 'the server is answering'
            printf '%s\n' "$body" | jq -r '.data[].id' 2>/dev/null | sed 's/^/    /' >&2 || printf '    %s\n' "$body" >&2
            return 0
        fi
        sleep 5
    done
    warn "no answer from http://127.0.0.1:${PORT}/v1/models after 15 minutes"
    ( cd "$PROJECT_DIR" && docker compose logs --tail 40 ) >&2 || true
    die 'the server did not come up — see the log above'
}

final_note() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    cat >&2 <<EOF

${C_OK}==>${C_RESET} whisper is serving on http://${ip:-<ip>}:${PORT}

    list what it serves
      curl -s http://${ip:-<ip>}:${PORT}/v1/models | jq -r '.data[].id'

    transcribe on the iGPU, then the same clip on the NPU — the only difference
    is the model field
      curl -s http://${ip:-<ip>}:${PORT}/v3/audio/transcriptions \\
        -F model=${DEFAULT_MODEL}-gpu -F language=en -F temperature=0 \\
        -F file=@/path/to/clip.mp3
      curl -s http://${ip:-<ip>}:${PORT}/v3/audio/transcriptions \\
        -F model=${DEFAULT_MODEL}-npu -F language=en -F temperature=0 \\
        -F file=@/path/to/clip.mp3

    mp3 and wav only; temperature=0 or OVMS samples at 1.0.

    manage
      cd ${PROJECT_DIR} && docker compose logs -f
      cd ${PROJECT_DIR} && \$EDITOR .env && bash prepare-models.sh && docker compose up -d
EOF
}

check_devices
install_docker
fix_storage_driver
install_stack
write_env
prepare_models
compose_up
wait_for_api
final_note
