import sys, importlib.util, pathlib

def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    sys.path.insert(0, str(p.parent))   # make sibling modules (llm_client) importable
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

ev = _load("eval_cwb")

def test_parse_judge_score_extracts_integer():
    assert ev.parse_judge_score("Reasoning... SCORE: 4") == 4
    assert ev.parse_judge_score("SCORE: 5\n") == 5

def test_parse_judge_score_clamps_and_defaults():
    assert ev.parse_judge_score("no score here") is None
    assert ev.parse_judge_score("SCORE: 9") == 5     # clamp high
    assert ev.parse_judge_score("SCORE: 0") == 1     # clamp low
