#!/usr/bin/env python3
"""Stage ④a: merge the LoRA adapter into the base, save bf16 safetensors.

Avoids PeftModel.from_pretrained — peft 0.19.1 + transformers 5.12 trip a
WeightConverter('distributed_operation') bug in its weight-conversion path.
Instead we rebuild the adapter via get_peft_model (the same path that trained
cleanly) and load the trained weights with set_peft_model_state_dict, then
merge_and_unload. Runs on the GB10 (ollama scaled to 0 → GPU free, ~62GB)."""
import argparse, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model, set_peft_model_state_dict
from safetensors.torch import load_file

BASE = "Qwen/Qwen3-Coder-30B-A3B-Instruct"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default="adapter")
    ap.add_argument("--out", default="merged")
    a = ap.parse_args()
    tok = AutoTokenizer.from_pretrained(BASE)
    model = AutoModelForCausalLM.from_pretrained(BASE, dtype=torch.bfloat16, device_map="cuda")
    cfg = LoraConfig.from_pretrained(a.adapter)
    model = get_peft_model(model, cfg)
    state = load_file(f"{a.adapter}/adapter_model.safetensors")
    load_res = set_peft_model_state_dict(model, state)
    print("ADAPTER-LOAD:", load_res)
    model = model.merge_and_unload()
    model.save_pretrained(a.out, safe_serialization=True)
    tok.save_pretrained(a.out)
    print("MERGED", a.out)

if __name__ == "__main__":
    main()
