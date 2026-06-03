# LLM stack (bee001) — llama.cpp Vulkan + Open WebUI

GPU-accelerated local inference on the Strix Halo iGPU (Radeon 8060S, gfx1151)
via RADV Vulkan. `llama-server` exposes an OpenAI-compatible API; Open WebUI is
the frontend. LAN/Tailscale only — no public Traefik route (yet).

## Host-specific bits (adjust per machine)
- `group_add: 991 / 44` are the host's **render** and **video** GIDs
  (`getent group render video`). Required so the container can open the GPU.
- `devices: /dev/dri/renderD128 + card1` — the GPU nodes.
- Models live on CephFS at `/srv/dm/ceph/llm/models/` (NOT in this repo —
  gitignored + excluded from restic; they're large and re-downloadable).
- WebUI data (chats/config/RAG) at `/srv/dm/ceph/llm/webui-data/` — this IS
  backed up by restic (irreplaceable).

## Models
Download with the HF CLI, e.g.:
  hf download bartowski/Qwen_Qwen3.6-35B-A3B-GGUF \
    Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf --local-dir /srv/dm/ceph/llm/models
Then set the `-m /models/<file>` and `--alias` in compose.yaml's llama-server
command. NOTE: llama-server serves ONE model per process — to run several,
add more llama-server services on different ports and add each as an
OpenAI endpoint in Open WebUI.

## Reach it
http://<bee001-LAN-or-tailscale-IP>:3000  (create admin account on first visit)
