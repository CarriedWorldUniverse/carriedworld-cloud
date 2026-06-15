import importlib.util, pathlib

def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

ec = _load("extract_corpus")
is_ours, top_level_funcs = ec.is_ours, ec.top_level_funcs

def test_is_ours_excludes_generated_vendor_and_cairn():
    assert is_ours("herald/internal/identity/roles.go")
    assert not is_ours("herald/internal/foo.pb.go")          # generated
    assert not is_ours("nexus/vendor/x/y.go")                # vendored
    assert not is_ours("cairn/server/web.go")                # upstream repo
    assert is_ours("cw/internal/cli/tenant/tenant_test.go")  # keep tests (our test style)

def test_top_level_funcs_extracts_whole_func_bodies():
    src = (
        "package x\n\n"
        "func Add(a, b int) int {\n\treturn a + b\n}\n\n"
        "func Sub(a, b int) int {\n\tif a > b {\n\t\treturn a - b\n\t}\n\treturn b - a\n}\n"
    )
    funcs = top_level_funcs(src)
    names = {f["name"] for f in funcs}
    assert names == {"Add", "Sub"}
    add = next(f for f in funcs if f["name"] == "Add")
    assert add["code"].strip().endswith("}")
    assert "return a + b" in add["code"]

def test_top_level_funcs_handles_methods_with_receivers():
    src = "package x\n\nfunc (l *LRU) Get(k int) (int, bool) {\n\treturn 0, false\n}\n"
    funcs = top_level_funcs(src)
    assert [f["name"] for f in funcs] == ["Get"]
