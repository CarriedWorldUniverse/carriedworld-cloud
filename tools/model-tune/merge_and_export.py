#!/usr/bin/env python3
"""Stage ④a: merge the LoRA adapter into the base, save bf16 safetensors.

peft 0.19.1 + transformers 5.12 break in convert_peft_adapter_state_dict_for_
transformers (WeightConverter('distributed_operation') TypeError), which is hit
by both PeftModel.from_pretrained and set_peft_model_state_dict. So we rebuild
the adapter modules with get_peft_model (clean — it's the path that trained) and
load the trained weights with a plain load_state_dict (mapping saved keys, which
lack the adapter-name infix, onto the model's `.default.` keys), bypassing the
broken conversion. peft's merge_and_unload (incl. the MoE ParamWrapper experts)
then folds correctly. Runs on the GB10 (ollama at 0 → GPU free, ~62GB)."""
import argparse, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model
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

    saved = load_file(f"{a.adapter}/adapter_model.safetensors")
    msd = model.state_dict()
    model_lora_keys = [k for k in msd if "lora_" in k]
    remap = {}
    for mk in model_lora_keys:
        cand = mk.replace(".default.", ".")
        src = cand if cand in saved else (mk if mk in saved else None)
        if src is not None:
            remap[mk] = saved[src].to(msd[mk].dtype)
    print(f"LORA-MATCH: {len(remap)}/{len(model_lora_keys)} model lora keys (saved={len(saved)})")
    if len(remap) != len(model_lora_keys):
        unmatched = [k for k in model_lora_keys if k not in remap][:5]
        print("UNMATCHED (sample):", unmatched)
        print("SAVED (sample):", list(saved)[:5])
        raise SystemExit("ABORT: key mismatch — refusing to merge partial LoRA")

    missing, unexpected = model.load_state_dict(remap, strict=False)
    print("loaded; unexpected lora:", [k for k in unexpected if "lora_" in k][:3])
    model = model.merge_and_unload()
    model.save_pretrained(a.out, safe_serialization=True)
    tok.save_pretrained(a.out)
    print("MERGED", a.out)

if __name__ == "__main__":
    main()
