# `whisper` — a standalone speech-to-text appliance

One Proxmox LXC, one container, one port. Inside it, Intel's
[OpenVINO Model Server](https://github.com/openvinotoolkit/model_server) serves whisper on an
Intel iGPU **and** an Intel NPU **at the same time, from a single process** — and a caller
chooses between the two accelerators with nothing but the `model` field of an ordinary
OpenAI-shaped multipart request:

```
POST /v3/audio/transcriptions   -F model=whisper-large-v3-turbo-gpu   → Arc 140V iGPU
POST /v3/audio/transcriptions   -F model=whisper-large-v3-turbo-npu   → AI Boost NPU
```

That is the whole idea. OVMS bakes `target_device:` into a `graph.pbtxt` inside each model
directory, so *a device is a property of a directory, not of a request*. Give it two
directories that share one set of weights and differ only in that line, list both in
`config.json`, and one server has two accelerators on tap.

This kit grew out of a call-transcription project that first ran OVMS inside its app LXC; it is
deliberately generic: nothing here knows about any particular consumer.

---

## What you need first

**On the Proxmox node** (nothing is installed *into* it by this kit):

* PVE 8 or 9, a Debian 13 CT template, and a free VMID.
* An Intel render node at `/dev/dri/renderD128`. The host kernel must have `xe` (Lunar Lake
  and newer) or `i915` loaded — `lsmod | grep -E 'xe|i915'`.
* For the NPU, `/dev/accel/accel0` and the `intel_vpu` module — `lsmod | grep intel_vpu`,
  kernel 6.6+. **A container cannot load these drivers.** It can only be handed a device the
  node has already brought up. On a machine with no NPU, see [GPU-only hosts](#gpu-only-hosts).

**The `render` gid trap.** `pct set --dev0 …,gid=N` sets the group of the device node *inside
the guest*, and the number that matters is the guest's, not the node's. On this cluster the
Proxmox node's `render` is gid **993** and Debian 13's is gid **992**; passing the node's
number produces a device nobody in the container can open, and OVMS then quietly falls back
to the CPU rather than failing. `create-lxc.sh` defaults to 992 and checks the guest
afterwards; `setup-inside.sh` checks again and refuses to guess.

## Three steps

```sh
# 1. the container, its network and its devices — run on the Proxmox node
VMID=301 HOSTNAME=whisper IP=dhcp \
SSH_PUBKEY="$(cat ~/.ssh/id_ed25519_proxmox.pub)" \
  ssh proxmox bash -s < create-lxc.sh

# 2. Docker, the stack, the models — run inside the guest
for f in setup-inside.sh compose.yaml compose.gpu-only.yaml prepare-models.sh .env.example; do
    scp $f root@<ip>:/root/whisper-kit-$f
done
ssh root@<ip> 'mv /root/whisper-kit-setup-inside.sh /root/setup-inside.sh &&
               KIT_DIR=/root bash /root/setup-inside.sh'

# 3. use it
curl -s http://<ip>:8000/v1/models | jq -r '.data[].id'
```

Copy the whole directory to the node and `create-lxc.sh` will do step 2 for you (it pushes
the kit with `pct push` and runs the setup itself); the two-step form above is for when the
kit lives somewhere else. Either way step 2 downloads several GB and compiles every servable,
which takes a few minutes — see [Timing](#timing).

Both scripts take every knob as an environment variable *or* a flag, and both print `--help`.
The ones you are most likely to change:

| | | |
|---|---|---|
| `VMID` `HOSTNAME` | 301, whisper | which container |
| `IP` `GW` | dhcp, 192.168.1.1 | `IP=192.168.1.50/24` for a static address |
| `CORES` `MEMORY` `DISK` | 8, 12288, 32 | **not round numbers** — see [Timing](#timing) |
| `GPU` `NPU` | 1, 1 | `NPU=0` on a host without one |
| `RENDER_GID` | 992 | the guest's `render` gid, not the node's |
| `MODELS` `DEVICES` | see below | what gets served |

`create-lxc.sh` refuses to touch a VMID that already exists unless you pass `FORCE=1` (destroy
and recreate) or `START_ONLY=1` (reuse it and re-run the setup, which is how you retry a
half-finished install).

---

## Calling it from anything

The API is a *subset* of the OpenAI Audio API, on `/v3` rather than `/v1`. Measured field by
field against `openvino/model_server:weekly`, because the failure mode here is **silence**,
not an error:

| field | what OVMS does |
|---|---|
| `model` | **required.** One of the names in `/v1/models`. A name it does not serve → **404**. |
| `file` | **mp3 or wav only.** Anything else → 400, "Received input file is not valid wav nor mp3 audio file". Transcode first. |
| `language` | honoured. |
| `temperature` | honoured, and **defaults to 1.0** — i.e. sampling — when the field is absent. **Always send `temperature=0`**, or the same clip gives different text each time. |
| `timestamp_granularities[]=word` | 400 unless the model was exported with `enable_word_timestamps`. |
| `timestamp_granularities[]=segment` | accepted, returns real segments — but it *changes the decode*. |
| `prompt`, `response_format`, `hotwords`, `vad_filter` | **accepted and silently ignored.** No error, identical answer. |

That last row is the one that bites. There is **no domain prompt, no hotword biasing and no
VAD** on this path, however cheerfully the server takes the fields. And the answer is
`{"text": "..."}` and nothing else — no segments, no `avg_logprob`, no `no_speech_prob`, no
`duration`, no `verbose_json`. A consumer that wants any of those has to supply them itself
(a client can get duration from `ffprobe` and compute a zlib `compression_ratio` itself).

There is also **no authentication**. The port is published on every interface because the
whole point is to be called from other machines; keep it on a trusted LAN or put a reverse
proxy in front of it.

```sh
curl -s http://192.168.1.50:8000/v3/audio/transcriptions \
  -F model=whisper-large-v3-turbo-gpu -F language=en -F temperature=0 \
  -F file=@call.mp3
```

### Switching a request between the GPU and the NPU

Change one string. Same host, same port, same process, same weights on disk:

```sh
-F model=whisper-large-v3-turbo-gpu     # Arc 140V iGPU
-F model=whisper-large-v3-turbo-npu     # AI Boost NPU
-F model=whisper-medium-gpu             # a different model, on the iGPU
-F model=whisper-gpu                    # alias: whatever DEFAULT_MODEL is, on the iGPU
-F model=whisper-npu                    # alias: the same, on the NPU
```

The `whisper-gpu` / `whisper-npu` aliases are extra `config.json` names pointing at
`DEFAULT_MODEL`'s graph directories — OVMS is happy to load one graph under two names. They
exist so a consumer can hard-code a stable model string and survive a model swap: change
`DEFAULT_MODEL` in `.env`, re-run `prepare-models.sh`, and every caller using the alias moves
with it.

For a consumer with a health probe: `GET /v1/models` answers in the OpenAI shape, so "is the
name I want in that list" is a complete readiness check.

---

## Changing what it serves

Everything lives in `/opt/whisper/.env`:

```sh
MODELS=OpenVINO/whisper-large-v3-turbo-fp16-ov,OpenVINO/whisper-medium-fp16-ov
DEVICES=GPU,NPU
DEFAULT_MODEL=whisper-large-v3-turbo
```

Every model is compiled for every device, so this is a 2 × 2 = four servables plus two
aliases. Then:

```sh
cd /opt/whisper
$EDITOR .env
bash prepare-models.sh     # downloads what is new, rewrites config.json from scratch
docker compose up -d --force-recreate
```

`prepare-models.sh` is safe to re-run: a repo whose IR is already on disk is not
re-downloaded (`FORCE_PULL=1` overrides), and `config.json` is rebuilt from scratch every
time — which is what makes *removing* a model from `.env` actually remove it. Deleting the
now-unreferenced `/models/<org>/<repo>` directory is a manual step, on purpose.

**Models must already be OpenVINO IR** — the `OpenVINO/` org on HuggingFace publishes them.
Pointing `--source_model` at a plain transformers checkpoint produces no model, silently.

Names: an entry may be `repo=alias`; without one the alias is the repo basename minus its
precision suffix, so `OpenVINO/whisper-large-v3-turbo-fp16-ov` serves as
`whisper-large-v3-turbo-gpu` rather than the unreadable `whisper-large-v3-turbo-fp16-ov-gpu`.
Served names are always `<alias>-<device>`, lower-cased.

### How the model repository is laid out

Worth knowing, because it is the mechanism the whole appliance rests on:

```
/models/
├── config.json                                  ← one entry per servable
├── OpenVINO/whisper-large-v3-turbo-fp16-ov/     ← the weights, downloaded once (1.5 GB)
├── OpenVINO/whisper-medium-fp16-ov/             ← (1.4 GB)
├── graphs/
│   ├── whisper-large-v3-turbo-gpu/              ← 68 KB: symlinks + its own graph.pbtxt
│   │   ├── graph.pbtxt                              target_device: "GPU"
│   │   ├── openvino_encoder_model.bin -> /models/OpenVINO/…/openvino_encoder_model.bin
│   │   └── …
│   └── whisper-large-v3-turbo-npu/              ← 68 KB: the same links, target_device: "NPU"
└── .ovms_cache/                                 ← compiled blobs, GPU .cl_cache and NPU .blob
```

A graph directory is a symlink farm plus one 1 KB text file, so N devices cost N × 68 KB, not
N × 1.5 GB. OVMS follows the symlinks — verified, not assumed.

`config.json` is exactly:

```json
{"model_config_list": [],
 "mediapipe_config_list": [
   {"name": "whisper-large-v3-turbo-gpu", "base_path": "graphs/whisper-large-v3-turbo-gpu"},
   {"name": "whisper-large-v3-turbo-npu", "base_path": "graphs/whisper-large-v3-turbo-npu"},
   {"name": "whisper-medium-gpu",         "base_path": "graphs/whisper-medium-gpu"},
   {"name": "whisper-medium-npu",         "base_path": "graphs/whisper-medium-npu"},
   {"name": "whisper-gpu",                "base_path": "graphs/whisper-large-v3-turbo-gpu"},
   {"name": "whisper-npu",                "base_path": "graphs/whisper-large-v3-turbo-npu"}]}
```

`base_path` is relative to the directory holding `config.json`.

> **Why this works when two servers on one repository did not.** OVMS rewrites `graph.pbtxt`
> on every start in `--source_model` mode — which is why the old two-container layout needed
> two separate volumes, and why a simultaneous restart of both could leave the loser running
> on the other's device. In `--config_path` mode it does **not**: verified here by comparing
> mtimes across a start and a restart, and by confirming the two files still read `"GPU"` and
> `"NPU"` afterwards. `prepare-models.sh` writes each graph with `ovms --configure`, the
> server's own tool, so the thing that writes the graph is the thing that reads it.

## Upgrading the server

```sh
cd /opt/whisper
$EDITOR .env                       # OVMS_IMAGE_TAG=weekly-20261015, say
docker compose pull && docker compose up -d
```

**Pin a tag; do not use `latest`.** `openvino/model_server:latest` and `:latest-gpu` (the July
2026 builds) do not work on Lunar Lake at all — the GPU plugin dies in
`contexts.count(device_id)` and the NPU compiler answers "unable to compile on the given
platform". `weekly` (2026-08-21 or newer) works on both devices.

Compiled blobs are **not** guaranteed compatible across OpenVINO releases. After a major
upgrade, expect one slow start while `.ovms_cache` refills; if a servable will not load,
`docker compose down && docker volume rm whisper_models` and re-run `prepare-models.sh` is the
big hammer (it re-downloads too).

## GPU-only hosts

Compose has no conditionals and refuses to start a service whose device node does not exist,
so the NPU device line is factored into an override:

```sh
# in .env
DEVICES=GPU
COMPOSE_FILE=compose.yaml:compose.gpu-only.yaml
```

`setup-inside.sh --npu 0` writes both of those for you, and `create-lxc.sh` with `NPU=0`
passes only the render node. `devices:` is a replace-not-merge list in compose, which is why
the override restates the GPU line.

---

## Timing

Measured 2026-08-31 on LXC 301 (Core Ultra 7 258V, Arc 140V + AI Boost, 8 cores / 12 GB),
OVMS weekly built 2026-08-21, over 15 duration-stratified public-safety radio calls the author
benchmarks everything with (94.1 s of audio, 0.24 s to 44.5 s), `temperature=0`, one request
at a time. Throughput is audio seconds per wall-clock second.

| model | device | wall | throughput |
|---|---|---|---|
| `large-v3-turbo-fp16` | **GPU** | 3.8 s | **24.7x** |
| `large-v3-turbo-fp16` | **NPU** | 7.2 s | **13.1x** |
| `medium-fp16` | GPU | 6.8 s | 13.8x |
| `medium-fp16` | NPU | 9.2 s | 10.2x |

`large-v3-turbo-fp16` is the choice on both devices: the most accurate model of the set *and*
comfortably faster than `medium`. The iGPU is the faster device by ~1.9x.

**Nothing else may hold the GPU.** The single largest effect measured in this whole exercise
was not a setting on this box at all. While a *second, idle* OVMS container on another LXC
still had the same render node open, this appliance's iGPU path ran at **16.0x**; the moment
that container was removed the identical benchmark gave **24.7x**. A 35 % loss to a container
that was doing nothing. The NPU path did not move. If the iGPU number looks low, find out
what else has `/dev/dri/renderD128` open before tuning anything here.

**Cores help the GPU path, and only it.** Whisper's front half — mp3 decode, the mel
spectrogram, tokenisation — runs on the CPU on the way to the accelerator. Identical
container, same warm cache, differing only in `pct set --cores`:

| cores | turbo GPU | turbo NPU |
|---|---|---|
| 4 | 19.9x | 12.6x |
| **8** | **24.7x** | 12.7x |

26 % for the iGPU, nothing for the NPU — which spends proportionally more of each request
inside the accelerator. 8 GB of RAM also puts a four-servable config into swap; 12 GB does not.

**Start-up.** Six servables, empty cache: **220 s**. The same six with the cache warm in the
volume: **5–20 s**, including after a host reboot. That gap is the entire reason `--cache_dir`
points into the volume — OVMS's default is `/opt/cache` *inside the image*, where every
restart repays the compile.

### Do the two devices really run in parallel?

Yes. And you should still send everything to the iGPU.

The parallelism is real, and the proof is host-side, from counters the guest cannot fake:
`/sys/devices/pci0000:00/0000:00:0b.0/npu_busy_time_us` and the `xe` driver's
`gtidle/idle_residency_ms`, sampled either side of a fixed workload. Idle baseline over 10 s:
NPU 0 ms busy, GPU 99.9 % idle.

| the only thing that differed | wall | **NPU busy** | **GPU busy** |
|---|---|---|---|
| `-F model=whisper-large-v3-turbo-gpu` | 5.1 s | **0 ms — 0 %** | **3.5 s — 68 %** |
| `-F model=whisper-large-v3-turbo-npu` | 8.4 s | **6.8 s — 80 %** | **0 ms — 0 %** |

A clean mirror image, one process, one port, one set of weights on disk. Under simultaneous
load both counters climb together — **NPU 89 % and GPU 57 % busy over the same 28 s window** —
so the two engines genuinely execute at the same time.

What that is *worth* is another question. 188.2 s of audio, every arrangement measured the
same way:

| arrangement | wall | aggregate |
|---|---|---|
| **GPU alone, 1 request in flight** | **7.5 s** | **25.1x** |
| GPU + NPU, 1 request in flight each | 9.3 s | 20.3x |
| GPU alone, 4 requests in flight | 10.9 s | 17.3x |
| GPU + NPU, 4 requests in flight each | 13.0 s | 14.5x |
| NPU alone, 1 request in flight | 14.8 s | 12.7x |
| NPU alone, 4 requests in flight | 16.2 s | 11.6x |

**The fastest row is the simplest one.** Adding the NPU to a busy iGPU makes the box slower
(20.3x against 25.1x), and so does adding concurrency to either device (17.3x against 25.1x).
Both effects have the same cause in different places: on Lunar Lake the iGPU and the NPU share
one LPDDR5X memory subsystem, and the graphs carry `NUM_STREAMS: 1`, so parallel requests to
one servable simply queue — at 4-deep, mean latency is 5x worse for no throughput at all.

So treat the NPU as a **failover lane, not extra capacity**: somewhere to send work when the
iGPU is unavailable, not a second engine to run beside it. A router should keep
`concurrency: 1` on both and prefer the iGPU.

## Troubleshooting

**`available devices: CPU` and nothing else, or everything is mysteriously slow.** The
permission story, in order: `ls -l /dev/dri /dev/accel` inside the guest — the group must be
the guest's `render` gid; `getent group render` — that is the number; `RENDER_GID` in
`/opt/whisper/.env` must equal it, because that is what compose puts in the container's
supplementary groups. If the device node's group is wrong, fix it on the **node**
(`pct set <VMID> --dev0 /dev/dri/renderD128,gid=992,mode=0660`), not in the guest. OVMS does
not fail on a device it cannot open; it falls back, which is why this is a
read-the-logs-carefully problem rather than a crash. `docker compose logs | grep 'Available
devices'` should say `CPU, GPU, NPU`.

**The container reports healthy but nothing transcribes.** It should not any more, but this is
worth knowing: OVMS binds the REST port and answers `GET /v1/models` with `{"data":[]}` about
one second after start, then compiles for minutes. A healthcheck that only asks "did it
answer" goes green immediately. The one in `compose.yaml` greps for an `"id"` in the response
for exactly this reason.

**A model 404s.** `POST /v3/audio/transcriptions` with a name OVMS does not serve answers 404
"Mediapipe graph definition with requested name is not found". Check `GET /v1/models` — and
remember the served name is `<alias>-<device>`, not the HuggingFace repo id.

**A 400 on a file that plays fine.** mp3 and wav only. m4a, ogg, flac and opus are all 400s.

**Every request gives different text.** You are not sending `temperature=0`, and OVMS's
default is 1.0.

**`contexts.count(device_id)` in the log, or the NPU compiler saying "unable to compile on the
given platform".** The image is too old. Pin `weekly`, not `latest`/`latest-gpu`.

**Every restart takes minutes.** `--cache_dir` is not reaching the volume, or the volume is
not writable. OVMS runs as uid 5000 in the image and the named volume is created root-owned,
which is why the service runs `user: "0:0"`. `docker compose logs | grep -i cache` should say
`Model cache is enabled: /models/.ovms_cache`.

**First start really is slow.** 220 s for six servables from empty is normal — the NPU
compile alone is ~95 s for `large-v3-turbo` and ~287 s for full `large-v3`. `start_period` on
the healthcheck is 400 s to cover it. Watch it happen: `docker compose logs -f | grep
'state changed to'`.

**Where things are.** Stack `/opt/whisper` (`compose.yaml`, `.env`, `prepare-models.sh`);
models the `whisper_models` volume; `docker compose logs -f`; inspect the repository with
`docker run --rm -v whisper_models:/m alpine ls -la /m /m/graphs`.
