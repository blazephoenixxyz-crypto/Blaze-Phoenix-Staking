#!/usr/bin/env python3
"""Every foundry profile must generate the SAME code as `default`.

DeployedSizeGate.t.sol measures the bytecode the suite deploys, and the mutants measure the
artefact the suite builds. Both claims are about the shipped contract only while every profile
compiles it identically. A profile that changes the optimizer, via_ir, the EVM version or the
compiler would make a green suite certify bytecode nobody ships. Port of bp-dex
assurance/profile_parity.py: profiles may differ in fuzz/invariant settings, never in codegen.

  python3 .github/scripts/profile_parity.py
"""
import json, subprocess, sys

KEYS = ("solc_version", "solc", "evm_version", "optimizer", "optimizer_runs", "via_ir",
        "bytecode_hash", "cbor_metadata")


def config(profile):
    env = dict(__import__("os").environ, FOUNDRY_PROFILE=profile)
    out = subprocess.run(["forge", "config", "--json"], capture_output=True, text=True, env=env)
    if out.returncode != 0:
        sys.exit(f"forge config failed for profile {profile}:\n{out.stderr}")
    c = json.loads(out.stdout)
    return {k: c.get(k) for k in KEYS}


def profiles():
    import tomllib
    t = tomllib.load(open("foundry.toml", "rb"))
    return sorted(t.get("profile", {}).keys())


base = config("default")
bad = 0
for p in profiles():
    if p == "default":
        continue
    c = config(p)
    for k in KEYS:
        if c[k] != base[k]:
            bad += 1
            print(f"profile '{p}': {k} = {c[k]!r}, default has {base[k]!r}")
if bad:
    sys.exit(1)
print(f"all profiles generate the same code as default ({', '.join(profiles())}).")
