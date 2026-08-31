#!/usr/bin/env bash
# prepare-models.sh — populate the `models` volume and write /models/config.json so
# that ONE OpenVINO Model Server serves every (model × device) pair at once.
#
# Run it inside the guest, from the directory holding compose.yaml:
#
#     cd /opt/whisper && bash prepare-models.sh
#     MODELS=OpenVINO/whisper-base-fp16-ov DEVICES=GPU bash prepare-models.sh
#
# Everything happens in throwaway containers built from the same image the server
# runs, so the tool that writes the graphs is the one that reads them, and nothing
# is installed on the host.  It is safe to re-run: an already-downloaded repo is
# left alone (pass FORCE_PULL=1 to re-fetch) and config.json is rewritten from
# scratch every time, which is what makes editing .env and re-running work.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")"

if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
fi
step() { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*" >&2; }
info() { printf '%s  ·%s %s\n'   "$C_DIM"  "$C_RESET" "$*" >&2; }
ok()   { printf '%s  ✓%s %s\n'   "$C_OK"   "$C_RESET" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

# .env is the source of truth, but an explicit environment variable overrides it
# for a one-off run (`MODELS=… bash prepare-models.sh`).  Sourcing .env would
# clobber those, so the pre-set values are saved first and put back afterwards.
for v in MODELS DEVICES DEFAULT_MODEL PORT; do
    [[ -n ${!v:-} ]] && declare "__override_$v=${!v}"
done
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi
for v in MODELS DEVICES DEFAULT_MODEL PORT; do
    o="__override_$v"
    [[ -n ${!o:-} ]] && declare "$v=${!o}"
done
MODELS=${MODELS:-OpenVINO/whisper-large-v3-turbo-fp16-ov}
DEVICES=${DEVICES:-GPU}
DEFAULT_MODEL=${DEFAULT_MODEL:-}
FORCE_PULL=${FORCE_PULL:-0}

[[ -f compose.yaml ]] || die "no compose.yaml here — run this from the stack directory (/opt/whisper)"
command -v docker >/dev/null || die 'docker is not installed'

# Every step runs in a throwaway container off the compose service, so it inherits
# the image tag, the `models` volume, user 0:0 and the device passthrough without
# any of it being restated here.  --no-deps and a /bin/bash entrypoint because
# `docker compose run SERVICE --pull …` would have compose eat the flags.
ovms() {
    docker compose run --rm --no-deps --entrypoint /bin/bash ovms -c "$1"
}

# --------------------------------------------------------------------------- #
# names
# --------------------------------------------------------------------------- #
# An entry is `repo` or `repo=alias`.  Without an explicit alias the alias is the
# repo basename minus its precision suffix, so OpenVINO/whisper-large-v3-turbo-fp16-ov
# serves as whisper-large-v3-turbo-gpu and whisper-large-v3-turbo-npu rather than
# the unreadable whisper-large-v3-turbo-fp16-ov-gpu.
alias_for() {
    local base=${1##*/}
    base=${base%-ov}
    base=$(printf '%s' "$base" | sed -E 's/-(fp16|fp32|bf16|int8|int4|nf4)$//')
    printf '%s' "$base"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

IFS=',' read -r -a MODEL_ENTRIES <<<"$MODELS"
IFS=',' read -r -a DEVICE_LIST   <<<"$DEVICES"
(( ${#MODEL_ENTRIES[@]} )) || die 'MODELS is empty'
(( ${#DEVICE_LIST[@]} ))   || die 'DEVICES is empty'

declare -a REPOS=() ALIASES=()
for entry in "${MODEL_ENTRIES[@]}"; do
    entry=$(printf '%s' "$entry" | tr -d '[:space:]')
    [[ -z $entry ]] && continue
    if [[ $entry == *=* ]]; then repo=${entry%%=*}; al=${entry#*=}; else repo=$entry; al=$(alias_for "$entry"); fi
    [[ $repo == */* ]] || die "MODELS entry '$repo' is not an <org>/<repo> HuggingFace id"
    REPOS+=("$repo"); ALIASES+=("$al")
done

declare -a DEVS=()
for d in "${DEVICE_LIST[@]}"; do
    d=$(printf '%s' "$d" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    [[ -z $d ]] && continue
    case $d in GPU|NPU|CPU|AUTO) ;; *) die "DEVICES entry '$d' is not one of GPU, NPU, CPU, AUTO" ;; esac
    DEVS+=("$d")
done

step "models: ${REPOS[*]}"
step "devices: ${DEVS[*]}"

# --------------------------------------------------------------------------- #
# 1. download each repo once
# --------------------------------------------------------------------------- #
# `--pull` lands the repo at /models/<org>/<name>/ — flat, no version directory,
# with a graph.pbtxt beside the IR.  That copy is the SHARED one: the per-device
# directories below reference it and never duplicate the 1.5 GB of weights.
for i in "${!REPOS[@]}"; do
    repo=${REPOS[$i]}
    step "downloading $repo"
    if [[ $FORCE_PULL == 1 ]]; then
        ovms "rm -rf '/models/${repo}'" >/dev/null
    fi
    ovms "
        set -e
        if [ -f '/models/${repo}/openvino_encoder_model.xml' ]; then
            echo 'already present, skipping the download'
        else
            /ovms/bin/ovms --pull --source_model '${repo}' --task speech2text \
                           --model_repository_path /models
        fi
        test -f '/models/${repo}/openvino_encoder_model.xml'
    " || die "could not download $repo — is it an OpenVINO IR repo? (in-server conversion of a transformers checkpoint does not work on this platform)"
    ok "$repo"
done

# --------------------------------------------------------------------------- #
# 2. one graph directory per (model, device)
# --------------------------------------------------------------------------- #
# OVMS bakes `target_device:` into graph.pbtxt, so a device is a property of the
# *directory*, not of a request — which is exactly what lets one process serve
# both: two directories, two graphs, two target_devices, one set of weights.
#
# The weights are shared by pointing each graph's `models_path` at the downloaded
# repo instead of at its own directory ("./", which is what --configure writes).
declare -a SERVABLES=() SERVABLE_DIRS=()
for i in "${!REPOS[@]}"; do
    repo=${REPOS[$i]}; al=${ALIASES[$i]}
    for dev in "${DEVS[@]}"; do
        name="${al}-$(lower "$dev")"
        dir="/models/graphs/${name}"
        step "graph $name  ($repo on $dev)"
        ovms "
            set -e
            mkdir -p '$dir'
            # --configure writes a graph.pbtxt for this task and device.  It needs the
            # model's config.json to infer the pipeline, so the directory gets a
            # symlink farm of the repo's small files; the weights stay where they are.
            for f in /models/${repo}/*; do
                b=\$(basename \"\$f\")
                case \"\$b\" in graph.pbtxt|.git) continue ;; esac
                ln -sfn \"\$f\" '$dir'/\"\$b\"
            done
            /ovms/bin/ovms --configure --model_path '$dir' --task speech2text --target_device '$dev'
            test -f '$dir/graph.pbtxt'
            grep -q 'target_device: \"$dev\"' '$dir/graph.pbtxt' \
              || { echo 'graph.pbtxt does not name $dev:'; cat '$dir/graph.pbtxt'; exit 1; }
        " || die "could not configure $name"
        SERVABLES+=("$name"); SERVABLE_DIRS+=("graphs/${name}")
        ok "$name"
    done
done

# --------------------------------------------------------------------------- #
# 3. config.json — one mediapipe entry per servable, plus the short aliases
# --------------------------------------------------------------------------- #
# Rewritten from scratch on every run so that removing a model from .env actually
# removes it.  `base_path` is relative to the directory holding config.json.
#
# The short aliases (whisper-gpu, whisper-npu) are extra names on the SAME graph
# directory as DEFAULT_MODEL's; OVMS is happy to load one graph under two names,
# and it gives every consumer a stable model string that survives a model swap.
step 'writing /models/config.json'
ALIAS_JSON=''
if [[ -n $DEFAULT_MODEL ]]; then
    found=0
    for al in "${ALIASES[@]}"; do [[ $al == "$DEFAULT_MODEL" ]] && found=1; done
    if (( found )); then
        for dev in "${DEVS[@]}"; do
            ldev=$(lower "$dev")
            ALIAS_JSON+="{\"name\":\"whisper-${ldev}\",\"base_path\":\"graphs/${DEFAULT_MODEL}-${ldev}\"},"
        done
        info "aliases: $(for dev in "${DEVS[@]}"; do printf 'whisper-%s ' "$(lower "$dev")"; done)-> ${DEFAULT_MODEL}"
    else
        warn "DEFAULT_MODEL='$DEFAULT_MODEL' is not one of the aliases (${ALIASES[*]}) — no short names registered"
    fi
fi

ENTRIES=''
for i in "${!SERVABLES[@]}"; do
    ENTRIES+="{\"name\":\"${SERVABLES[$i]}\",\"base_path\":\"${SERVABLE_DIRS[$i]}\"},"
done
CONFIG="{\"model_config_list\":[],\"mediapipe_config_list\":[${ENTRIES}${ALIAS_JSON}]}"
CONFIG=${CONFIG/,]\}/]\}}   # trailing comma from the last entry

ovms "printf '%s' '$CONFIG' | python3 -m json.tool > /models/config.json 2>/dev/null \
           || printf '%s\n' '$CONFIG' > /models/config.json; cat /models/config.json"

N_ALIAS=0
[[ -n $ALIAS_JSON ]] && N_ALIAS=$(printf '%s' "$ALIAS_JSON" | grep -o '"name"' | wc -l)
ok "${#SERVABLES[@]} servables + ${N_ALIAS} aliases"

cat >&2 <<EOF

${C_OK}==>${C_RESET} ready — start (or restart) the server to load them

    docker compose up -d
    docker compose logs -f          # first start compiles: ~10 s per GPU servable,
                                    # ~95 s per NPU servable for large-v3-turbo
    curl -s localhost:${PORT:-8000}/v1/models | jq -r '.data[].id'
EOF
