# Gemma 4 12B-it Local-Cloud Install Plan

> **For the engineer:** execute phase-by-phase; each task has exact commands + a verification step. Steps marked **⚠VERIFY** are bleeding-edge (sm_120 + 3-day-old Gemma 4) — confirm empirically before moving on. Run on **dMon** (`ssh jacinta@100.91.185.71`, passwordless sudo).

**Goal:** serve Gemma 4 12B-it as an OpenAI-compatible endpoint inside dMon's k3s, GPU-scheduled on the RTX 5090, as the local fallback / cheap-lane LLM (NEX — [[project_local_fallback_llm_k3s_gpu]]).

**Architecture:** k3s schedules a single vLLM pod onto the 5090 via the NVIDIA device plugin (`nvidia.com/gpu: 1`). vLLM serves Gemma 4 12B-it with **on-the-fly FP8** quantization and an OpenAI `/v1` API behind a ClusterIP Service. The funnel's cheap/fallback model lane points at that Service.

**Tech stack:** k3s (containerd), NVIDIA device plugin v0.19.0, nvidia-container-toolkit (installed), vLLM (cu130 nightly), Gemma 4 12B-it (BF16 weights → FP8 at load), HF Hub.

**Decisions (brainstorm 2026-06-06):** Gemma 4 12B-it · FP8 (vLLM dynamic) · vLLM · NVIDIA device plugin.

## Execution status
- **Phase 1 ✅ DONE (2026-06-06).** Executed via **RuntimeClass, not the default-runtime change** — k3s had already auto-added the `nvidia` containerd runtime (config v2, line 51), so **no `config.toml.tmpl` edit and no k3s restart** (CWB stayed up). Created RuntimeClass `nvidia` (handler `nvidia`) + deployed the device plugin patched with `runtimeClassName: nvidia`. `nvidia.com/gpu: 1` allocatable; smoke pod saw the 5090. **Consequence:** every GPU pod must set `runtimeClassName: nvidia` (the vLLM manifest does). The Task-1 default-runtime/restart steps below remain as the *fallback* for a setup lacking the auto-added runtime.
- **Phase 2 ▶ IN PROGRESS (2026-06-06).** **No HF token needed** — Gemma 4 is the first Gemma under **Apache 2.0 / ungated**; vLLM pulls anonymously. Task 4 (HF token secret) is dropped. Repo is `google/gemma-4-12B-it` (**case-sensitive, capital B**). PVC + vLLM Deployment applied; watching the ~23 GB pull → FP8 load.
- **Phase 3 ⏳** after Phase 2.

---

## Hardware reality (measured on dMon)

| | |
|---|---|
| GPU | **RTX 5090 Laptop — 24 GB GDDR7** (not the 32 GB desktop part) |
| Compute capability | **sm_120** (Blackwell) |
| Driver / CUDA | **595.71.05 / 13.2** — already above the sm_120 floors (≥570 / ≥12.8) |
| k3s GPU scheduling | **not set up** — no `nvidia.com/gpu`, no nvidia runtime in k3s containerd |
| Toolkit | `nvidia-ctk` + `nvidia-container-runtime` **installed** |
| Disk (`/var/lib`) | 1.8 TB free |

**The 24 GB constraint drives everything:** Gemma 4 12B BF16 ≈ 23 GB weights → no KV-cache room → **quantization is mandatory.** FP8 ≈ ~12 GB weights leaves ~10–11 GB for KV-cache/activations, so context length is the knob we tune (Phase 2).

---

## Phase 1 — GPU scheduling in k3s

### Task 1: Make the NVIDIA runtime the default in k3s containerd

k3s ships its own containerd; it auto-detects `nvidia-container-runtime` (the toolkit is installed) and writes an `nvidia` runtime into the generated config. We make it the **default** so pods don't each need a RuntimeClass.

- [ ] **Step 1** — Confirm k3s already discovered the runtime template inputs:
  ```bash
  ssh jacinta@100.91.185.71 'nvidia-ctk --version; ls -la /var/lib/rancher/k3s/agent/etc/containerd/'
  ```
- [ ] **Step 2** — Create a containerd config **template** that sets the default runtime to `nvidia` (k3s merges `config.toml.tmpl`):
  ```bash
  ssh jacinta@100.91.185.71 'sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
    /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
  sudo sed -i "s/default_runtime_name = \"runc\"/default_runtime_name = \"nvidia\"/" \
    /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl'
  ```
  **⚠VERIFY:** the generated `config.toml` must already contain a `[...runtimes.nvidia]` block. If it does **not**, run `sudo nvidia-ctk runtime configure --runtime=containerd --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl --set-as-default` instead of the sed, then proceed.
- [ ] **Step 3** — Restart k3s and confirm the runtime took:
  ```bash
  ssh jacinta@100.91.185.71 'sudo systemctl restart k3s && sleep 20 && \
    grep -A2 "default_runtime_name" /var/lib/rancher/k3s/agent/etc/containerd/config.toml && \
    grep -c "runtimes.nvidia" /var/lib/rancher/k3s/agent/etc/containerd/config.toml'
  ```
  **Expected:** `default_runtime_name = "nvidia"` and the nvidia runtime block present. k3s pods must all be Running again (`sudo kubectl get pods -A | grep -v Running` → only Completed/none).

### Task 2: Deploy the NVIDIA device plugin

- [ ] **Step 1** — Apply the pinned device plugin (manifest committed at `clusters/dmon/gpu/nvidia-device-plugin.yaml`):
  ```bash
  ssh jacinta@100.91.185.71 'sudo kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.19.0/deployments/static/nvidia-device-plugin.yml'
  ```
- [ ] **Step 2** — Verify `nvidia.com/gpu` is now allocatable:
  ```bash
  ssh jacinta@100.91.185.71 'sudo kubectl -n kube-system get pods | grep nvidia-device-plugin; \
    sudo kubectl get node -o jsonpath="{.items[0].status.allocatable.nvidia\.com/gpu}"; echo'
  ```
  **Expected:** the device-plugin pod `Running`, and `1` GPU allocatable.

### Task 3: GPU smoke test in a pod

- [ ] **Step 1** — Run a throwaway CUDA pod (request the GPU) and read the card:
  ```bash
  ssh jacinta@100.91.185.71 'cat <<YAML | sudo kubectl apply -f -
  apiVersion: v1
  kind: Pod
  metadata: { name: gpu-smoke, namespace: nexus }
  spec:
    restartPolicy: Never
    containers:
      - name: smoke
        image: nvidia/cuda:13.0.0-base-ubuntu24.04
        command: ["nvidia-smi"]
        resources: { limits: { nvidia.com/gpu: 1 } }
  YAML
  sleep 15 && sudo kubectl logs -n nexus gpu-smoke | grep -E "5090|Driver"; \
  sudo kubectl delete pod -n nexus gpu-smoke --wait=false'
  ```
  **Expected:** `nvidia-smi` from inside the pod shows the RTX 5090. **⚠VERIFY** the in-pod CUDA base image tag exists (`nvidia/cuda:13.0.0-base-ubuntu24.04`); fall back to `12.9.0-base-ubuntu24.04` if not.
  **GATE:** do not proceed to Phase 2 until a pod can see the GPU.

---

## Phase 2 — Serve Gemma 4 12B-it with vLLM

### Task 4: HuggingFace access + weight cache

Gemma is license-gated on HF — the token must belong to an account that accepted the Gemma 4 license.

- [ ] **Step 1** — Create the HF token secret (token piped, never printed). Mint at huggingface.co with read scope after accepting the license at `https://huggingface.co/google/gemma-4-12b-it`:
  ```bash
  read -rs HF; printf '%s' "$HF" | ssh jacinta@100.91.185.71 \
    'sudo kubectl create secret generic hf-token -n nexus --from-file=token=/dev/stdin'
  ```
- [ ] **Step 2** — Create a hostPath PVC for the weight cache so a ~23 GB download survives pod restarts (manifest `clusters/dmon/gpu/gemma-weights-pvc.yaml`):
  ```bash
  ssh jacinta@100.91.185.71 'sudo mkdir -p /var/lib/nexus/hf-cache && \
    sudo kubectl apply -f -' < clusters/dmon/gpu/gemma-weights-pvc.yaml
  ```

### Task 5: Deploy vLLM

Manifest: `clusters/dmon/gpu/gemma-4-12b-vllm.yaml` (Deployment + Service, committed). Key flags, with the *why*:

| Flag / env | Value | Why |
|---|---|---|
| `--model` | `google/gemma-4-12b-it` | the instruction-tuned model |
| `--quantization` | `fp8` | on-the-fly FP8 (no pre-quantized repo needed); ~12 GB weights |
| `--kv-cache-dtype` | `fp8` | halves KV memory → more context on 24 GB |
| `--max-model-len` | `32768` | **conservative start** — full 256K KV won't fit in ~10 GB; tune up in Task 6 |
| `--gpu-memory-utilization` | `0.92` | leave headroom on the laptop card |
| `VLLM_FLASH_ATTN_VERSION` | `2` | **FA3 is broken on Blackwell**; Gemma 4 head dims fall back to TRITON_ATTN regardless |
| `HF_TOKEN` | from `hf-token` secret | license-gated download |
| image | `vllm/vllm-openai:nightly` | **⚠VERIFY** the nightly tag carries sm_120 kernels **and** Gemma 4 (Transformers ≥ 5.5.4). If not, build from the cu130 nightly wheel on `nvidia/cuda:13.0.0-runtime-ubuntu24.04` (build notes in the manifest comments). |

- [ ] **Step 1** — Apply:
  ```bash
  ssh jacinta@100.91.185.71 'sudo kubectl apply -f -' < clusters/dmon/gpu/gemma-4-12b-vllm.yaml
  ```
- [ ] **Step 2** — Watch it pull + load (first run downloads ~23 GB, then quantizes — several minutes):
  ```bash
  ssh jacinta@100.91.185.71 'sudo kubectl -n nexus logs -f deploy/gemma-vllm | grep -iE "Loading|quantiz|Started server|sm_120|error|CUDA"'
  ```
  **Expected:** ends with vLLM "Starting/Started the OpenAI API server" with **no** sm_120/kernel/OOM errors. **⚠VERIFY**: if OOM at load → lower `--max-model-len` to 16384 or `--gpu-memory-utilization` to 0.88. If a Gemma-4 architecture error → bump the image / Transformers (see Task 5 image note).

### Task 6: Verify the endpoint + tune context

- [ ] **Step 1** — Hit the OpenAI API from inside the cluster:
  ```bash
  ssh jacinta@100.91.185.71 'sudo kubectl -n nexus run curlcheck --rm -it --restart=Never --image=curlimages/curl -- \
    sh -c "curl -s http://gemma-vllm.nexus.svc.cluster.local:8000/v1/models; echo; \
    curl -s http://gemma-vllm.nexus.svc.cluster.local:8000/v1/chat/completions -H \"Content-Type: application/json\" \
    -d \"{\\\"model\\\":\\\"google/gemma-4-12b-it\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Say hi in 5 words.\\\"}]}\""'
  ```
  **Expected:** `/v1/models` lists the model; the completion returns a short reply.
- [ ] **Step 2** — Record measured throughput (tok/s) and VRAM (`nvidia-smi`); if VRAM has slack, raise `--max-model-len` (e.g. 65536) and re-apply. Note the final value in this doc.

---

## Phase 3 — Wire into the funnel (cheap/fallback lane)

Realizes [[feedback_model_routing_policy]]: premium orchestration on Opus, cheap/classification lanes local.

- [ ] **Task 7** — Point the funnel's cheap/summariser/fallback model lane at the local endpoint: provider = OpenAI-compatible, `base_url = http://gemma-vllm.nexus.svc.cluster.local:8000/v1`, `model = google/gemma-4-12b-it`, dummy API key. Use the existing per-aspect/network AI config seam (the Frame/configurability matrix [[project_configurability_arc_2026-05-25]]); no new code if the OpenAI-compatible provider already exists. **⚠VERIFY** vLLM's `json_object`/tool-format compatibility against the CheapModelFilter (mirror the DeepSeek lesson [[reference_deepseek_response_format]] — start with `json_object`, not strict `json_schema`).
- [ ] **Task 8** — End-to-end: route one real classification/summarise turn through the local lane; confirm the response comes from the pod (check vLLM logs show the request) and quality is acceptable. Roll back the lane config if not.

---

## Risks / open verifications
- **sm_120 + Gemma 4 are days-old.** The two load-bearing ⚠VERIFY points are (a) the vLLM nightly image actually carrying sm_120 kernels + Gemma 4 support, and (b) FP8 loading cleanly on the 24 GB card. Budget time here; the fallback is building vLLM from the cu130 nightly wheel.
- **Decode speed:** no FlashAttention-3 on Blackwell → TRITON_ATTN path; expect lower decode tok/s than datacenter benchmarks. Acceptable for a cheap/fallback lane.
- **Laptop thermals/power:** sustained inference on a laptop 5090 — watch `nvidia-smi` temps under load; cap concurrency if throttling.
- **Upgrade path:** once stable, revisit **W4A16/NVFP4** (~7–8 GB, +~68% throughput, more context headroom) per the research — a config swap, not a re-architecture.

## Reproducibility
Manifests live in `clusters/dmon/gpu/`. The host-level steps (Task 1 k3s runtime, Task 4 secret) are documented here because they touch host state outside k8s; everything else is `kubectl apply`.
