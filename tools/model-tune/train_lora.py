#!/usr/bin/env python3
"""Stage ③: bf16 LoRA SFT of qwen3-coder on the GB10 (no quantization).
Targets transformers 5.x / trl 1.6 / peft 0.19 — dtype= (not torch_dtype),
SFTConfig.max_length (not max_seq_length), SFTTrainer(processing_class=...)."""
import argparse, torch
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig
from trl import SFTConfig, SFTTrainer

BASE = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
TARGETS = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="dataset")
    ap.add_argument("--out", default="adapter")
    ap.add_argument("--base", default=BASE)   # override with a tiny model for fast API validation
    ap.add_argument("--epochs", type=float, default=3.0)
    ap.add_argument("--max-steps", type=int, default=-1)   # set small for the tiny-subset run
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--seq-len", type=int, default=2048)
    a = ap.parse_args()

    tok = AutoTokenizer.from_pretrained(a.base)
    model = AutoModelForCausalLM.from_pretrained(a.base, dtype=torch.bfloat16, device_map="cuda")
    model.config.use_cache = False
    ds = load_dataset("json", data_files={"train": f"{a.data}/train.jsonl",
                                          "val": f"{a.data}/val.jsonl"})
    cfg = SFTConfig(
        output_dir=a.out, num_train_epochs=a.epochs, max_steps=a.max_steps,
        per_device_train_batch_size=1, gradient_accumulation_steps=8,
        learning_rate=1e-4, lr_scheduler_type="cosine", warmup_ratio=0.03,
        bf16=True, gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        max_length=a.seq_len, logging_steps=5, eval_strategy="epoch",
        save_strategy="epoch", report_to=[])
    trainer = SFTTrainer(
        model=model, args=cfg, train_dataset=ds["train"], eval_dataset=ds["val"],
        processing_class=tok,
        peft_config=LoraConfig(r=a.rank, lora_alpha=a.rank * 2, lora_dropout=0.0,
                               target_modules=TARGETS, task_type="CAUSAL_LM"))
    trainer.train()
    trainer.save_model(a.out)
    print("ADAPTER-SAVED", a.out)

if __name__ == "__main__":
    main()
