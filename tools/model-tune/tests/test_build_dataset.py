import sys, json, importlib.util, pathlib

def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    sys.path.insert(0, str(p.parent))   # make sibling modules (llm_client) importable
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

bd = _load("build_dataset")

def test_to_example_builds_chat_triple():
    ex = bd.to_example("system std", "implement Add", "func Add(a,b int) int { return a+b }")
    assert ex["messages"][0] == {"role": "system", "content": "system std"}
    assert ex["messages"][1]["role"] == "user" and "implement Add" in ex["messages"][1]["content"]
    assert ex["messages"][2]["role"] == "assistant" and "func Add" in ex["messages"][2]["content"]

def test_synth_brief_uses_injected_client():
    calls = {}
    def fake_chat(messages, model, **kw):
        calls["model"] = model
        return "Implement a function that adds two ints."
    brief = bd.synth_brief({"name": "Add", "code": "func Add(a,b int) int { return a+b }"},
                           chat_fn=fake_chat, model="code")
    assert "adds two ints" in brief
    assert calls["model"] == "code"

def test_split_is_deterministic_and_disjoint():
    items = [{"messages": [{"role": "user", "content": str(i)}]} for i in range(100)]
    tr, va = bd.split(items, val_frac=0.1, seed=0)
    assert len(va) == 10 and len(tr) == 90
    seen = {json.dumps(x) for x in tr}
    assert all(json.dumps(x) not in seen for x in va)
