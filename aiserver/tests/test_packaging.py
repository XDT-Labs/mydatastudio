"""
Tests for what main.spec puts in the frozen aiserver.

These guard against failures that only exist in the built binary: every other
test runs against the venv, where all native libraries are present regardless
of what the spec collects.
"""
import ast
import re
from pathlib import Path

import pytest

SPEC_PATH = Path(__file__).resolve().parents[1] / "main.spec"


def _packages_given_to_collect_all() -> set:
    """Package names in main.spec's `for pkg in [...]: collect_all(pkg)` loop."""
    for node in ast.walk(ast.parse(SPEC_PATH.read_text())):
        if not (isinstance(node, ast.For) and isinstance(node.iter, ast.List)):
            continue
        calls = [
            call.func.id
            for call in ast.walk(node)
            if isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
        ]
        if "collect_all" in calls:
            return {element.value for element in node.iter.elts}
    pytest.fail("main.spec no longer has a collect_all loop")


def test_torchvision_native_ops_reach_the_frozen_binary():
    """
    Without its native ops, importing torchvision raises at import time, and
    transformers (hence sentence-transformers) cannot import in the frozen app:
    every local embedding request then fails.

    PyInstaller's contrib hook can't be relied on: torchvision 0.29 renamed `_C`
    to `_C_stable`, the hook still asks for `_C`, and that only surfaces as a
    build-log warning. So the spec must collect them itself. The name is read
    from torchvision rather than hardcoded so another rename can't pass silently.
    """
    from PyInstaller.utils.hooks import collect_all
    import torchvision

    assert "torchvision" in _packages_given_to_collect_all()

    extension_source = (Path(torchvision.__file__).parent / "extension.py").read_text()
    required = re.findall(r'_load_library\("(\w+)"\)', extension_source)
    assert required, "torchvision no longer names its extension in extension.py"

    _, _, hidden_imports = collect_all("torchvision")
    for extension in required:
        assert f"torchvision.{extension}" in hidden_imports, (
            f"{extension} would not be bundled by collect_all('torchvision')"
        )
