#!/usr/bin/env python3
"""Stage ④a: merge the LoRA adapter into the base and save bf16 safetensors.
Runs on the GB10 (ollama scaled to 0 → GPU free). ~62GB resident (in-place fold,
well under 128GB). Output feeds the GGUF conversion."""
import argparse, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

BASE = "Qwen/Qwen3-Coder-30B-A3B-Instruct"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default="adapter")
    ap.add_argument("--out", default="merged")
    a = ap.parse_args()
    tok = AutoTokenizer.from_pretrained(BASE)
    model = AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.bfloat16, device_map="cuda")
    model = PeftModel.from_pretrained(model, a.adapter)
    model = model.merge_and_unload()
    model.save_pretrained(a.out, safe_serialization=True)
    tok.save_pretrained(a.out)
    print("MERGED", a.out)

if __name__ == "__main__":
    main()
