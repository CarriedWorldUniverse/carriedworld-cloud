# dMon GPU stack (RTX 5090, sm_120)

GPU-scheduled local inference. Full procedure + host-level steps + risks: **[../../../docs/2026-06-06-gemma-4-12b-install-plan.md](../../../docs/2026-06-06-gemma-4-12b-install-plan.md)**.

## Apply order
1. **Host (once):** make `nvidia` the default k3s containerd runtime + restart k3s (plan Task 1).
2. **Device plugin:** `kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.19.0/deployments/static/nvidia-device-plugin.yml` (pinned v0.19.0). Confirm `nvidia.com/gpu: 1` allocatable.
3. **Secret (once):** `hf-token` (HF account that accepted the Gemma 4 license).
4. `kubectl apply -f gemma-weights-pvc.yaml`
5. `kubectl apply -f gemma-4-12b-vllm.yaml`

Endpoint: `http://gemma-vllm.nexus.svc.cluster.local:8000/v1` (OpenAI-compatible). The funnel cheap/fallback lane points here.

## Files
- `gemma-weights-pvc.yaml` — 60Gi weight cache (local-path).
- `gemma-4-12b-vllm.yaml` — vLLM Deployment + Service (Gemma 4 12B-it, FP8).
