#!/usr/bin/env python3
"""Prove the training stack end-to-end on the GB10 with a tiny model:
load -> attach LoRA -> one forward/backward/optimizer step on the GPU.
Exits 0 with a finite loss, non-zero otherwise. Uses a small Qwen to keep it fast."""
import sys, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model

MODEL = "Qwen/Qwen2.5-0.5B-Instruct"  # tiny; same family tooling as the 30B target

def main():
    assert torch.cuda.is_available(), "CUDA not available on the GB10"
    tok = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModelForCausalLM.from_pretrained(MODEL, dtype=torch.bfloat16).to("cuda")
    model = get_peft_model(model, LoraConfig(
        r=8, lora_alpha=16, lora_dropout=0.0,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"]))
    model.train()
    batch = tok(["func Add(a, b int) int { return a + b }"], return_tensors="pt").to("cuda")
    batch["labels"] = batch["input_ids"].clone()
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    loss = model(**batch).loss
    loss.backward(); opt.step(); opt.zero_grad()
    assert torch.isfinite(loss), f"non-finite loss {loss}"
    print(f"SMOKE-OK loss={loss.item():.4f}")

if __name__ == "__main__":
    sys.exit(main())
