# Owner(s): ["module: ci"]
"""TEMPORARY (DO NOT LAND): compare testintro's simulated enumeration against the real
device, for a platform/config + files. Used by the throwaway CI validation jobs that
run on real hardware (e.g. linux.idc.xpu). Exits non-zero on any mismatch. Delete this
file with the validation commit.

    python tools/testing/introspection/_validate_device.py linux-xpu/default test/test_xpu.py
"""

import sys
from pathlib import Path


# Run by path (python tools/.../_validate_device.py), so the package root isn't on
# sys.path. Append it (not prepend) so `tools` imports while the wheel torch in
# site-packages stays ahead of any repo torch/ source -- same bootstrap as collector.py.
if not __package__:
    sys.path.append(str(Path(__file__).resolve().parents[3]))

sys.path.insert(0, "test")  # let test files resolve sibling imports

from tools.testing.introspection import collector, platforms


def main() -> int:
    job = platforms.get_job(sys.argv[1])
    ok = True
    for f in sys.argv[2:]:
        mod = collector._import_target(
            f, gut=False, mod_name="real_" + f.replace("/", "_").replace(".", "_")
        )
        real = {f"{c}::{m}" for c, ms in collector._enumerate(mod).items() for m in ms}
        sim = {
            f"{c}::{m}"
            for c, ms in collector.enumerate_tests(f, job, use_cache=False).items()
            for m in ms
        }
        miss, extra = sorted(real - sim), sorted(sim - real)
        status = "MATCH" if real == sim else f"MISMATCH -{len(miss)} +{len(extra)}"
        print(f"=== {f}: real={len(real)} sim={len(sim)} {status}")
        for t in miss[:25]:
            print("  MISSING (real has, sim lacks):", t)
        for t in extra[:25]:
            print("  EXTRA   (sim has, real lacks):", t)
        ok = ok and real == sim
    print("VALIDATION_RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
