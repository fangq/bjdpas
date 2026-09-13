#!/usr/bin/env python3
"""Cross-validate the Pascal implementation against the reference pybj library.

For every sample below the script

  1. encodes it with pybj, decodes it with bjd2json and compares the JSON
     against the JSON produced by Python itself, and
  2. asks bjd2json to re-encode the document and decodes the result with pybj,
     comparing it against the original Python object.

Usage: python3 crosscheck.py [path-to-bjd2json]
"""

import json
import math
import os
import subprocess
import sys
import tempfile

try:
    import bjdata
except ImportError:
    print("skipped: the reference 'bjdata' python module is not installed")
    sys.exit(0)

TOOL = sys.argv[1] if len(sys.argv) > 1 else "./bjd2json"

SAMPLES = [
    ("null", None),
    ("true", True),
    ("int", 12345),
    ("negative int", -12345),
    ("big int", 2**40),
    ("float", 3.141592653589793),
    ("string", "hello, 世界"),
    ("empty string", ""),
    ("escapes", 'quote " backslash \\ newline \n tab \t'),
    ("array", [1, 2, 3, 4, 5]),
    ("mixed array", [1, "two", None, True, 4.5]),
    ("nested array", [[1, 2], [3, 4], [[5], [6]]]),
    ("object", {"a": 1, "b": "two", "c": None}),
    ("nested object", {"a": {"b": {"c": [1, 2, 3]}}}),
    ("empty containers", {"a": [], "b": {}}),
    ("wide ints", [-128, 127, 255, -32768, 65535, 2**31 - 1, 2**32 - 1]),
    ("floats", [0.1, 0.2, 1e300, -1e-300, 0.0]),
    ("deep", {"l%d" % i: list(range(i)) for i in range(1, 8)}),
    ("bytes", b"\xde\xad\xbe\xef"),
]

try:
    import numpy as np

    SAMPLES += [
        ("uint8 3-d array", np.arange(24, dtype=np.uint8).reshape(2, 3, 4)),
        ("float64 2-d array", np.linspace(0, 1, 12).reshape(3, 4)),
        ("int32 1-d array", np.array([-5, 0, 5, 2**30], dtype=np.int32)),
        ("float32 array", np.array([1.5, -2.25, 1e20], dtype=np.float32)),
        ("uint64 array", np.array([2**63 + 7, 1], dtype=np.uint64)),
        ("array in object", {"vol": np.ones((2, 2, 2), dtype=np.uint16)}),
    ]
except ImportError:
    print("note: numpy is missing, packed N-d array checks are skipped")


def norm(obj):
    """normalize for comparison: pybj returns packed arrays as numpy arrays,
    byte arrays as bytes and integral floats as floats"""
    if isinstance(obj, (bytes, bytearray)):
        return list(obj)
    if hasattr(obj, "tolist"):
        return norm(obj.tolist())
    if isinstance(obj, (list, tuple)):
        return [norm(v) for v in obj]
    if isinstance(obj, dict):
        return {k: norm(v) for k, v in obj.items()}
    if isinstance(obj, float) and obj.is_integer() and abs(obj) < 2**53:
        return int(obj)
    return obj


def run(args):
    res = subprocess.run([TOOL] + args, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.strip() or "exit %d" % res.returncode)
    return res.stdout.strip()


def main():
    fails = 0
    total = 0
    tmp = tempfile.mkdtemp(prefix="bjdcross")
    src = os.path.join(tmp, "in.bjd")
    dst = os.path.join(tmp, "out.bjd")

    for name, value in SAMPLES:
        for flags in ("ct", "", "c", "cts"):
            total += 1
            try:
                with open(src, "wb") as f:
                    f.write(bjdata.dumpb(value))
                got = json.loads(run([src]))
                if norm(got) != norm(value):
                    raise AssertionError("decode mismatch: %r != %r" % (got, value))
                run(["-O", flags, "-o", dst, src])
                with open(dst, "rb") as f:
                    back = bjdata.loadb(f.read(), object_pairs_hook=dict)
                if norm(back) != norm(value):
                    raise AssertionError("re-encode mismatch: %r != %r" % (back, value))
                print("  ok   %s [-O %s]" % (name, flags or "none"))
            except Exception as exc:                       # noqa: BLE001
                fails += 1
                print("  FAIL %s [-O %s]: %s" % (name, flags or "none", exc))

    print("\n%d check(s), %d failure(s)" % (total, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
