#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat client. Defaults to the local gateway."""
import json, urllib.request

DEFAULT_BASE = "http://100.91.185.71:4000/v1"  # LiteLLM gateway (dMon tailnet)

def chat(messages, model, base=DEFAULT_BASE, temperature=0.2, timeout=600, api_key="ollama"):
    body = json.dumps({"model": model, "temperature": temperature, "messages": messages}).encode()
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]["message"]["content"]
