#!/usr/bin/env bash
# Stand up the LoRA training venv on the GB10 (aarch64, CUDA 13.0).
# Primary path: pip cu130 wheels. If torch.cuda is False after this, fall back to
# the NGC PyTorch ARM container (see README "Fallback").
set -euo pipefail
cd "$HOME/model-tune"
python3 -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
# cu130 aarch64 (sbsa) wheels:
pip install torch --index-url https://download.pytorch.org/whl/cu130
pip install "transformers>=4.46" "peft>=0.13" "trl>=0.12" "datasets>=3.0" "accelerate>=1.0"
python -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO-CUDA')"
