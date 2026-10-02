#!/usr/bin/env python3
"""Proves a design pass changed no user-visible wording.

Collects every string literal in the SwiftUI sources (text, labels, help, messages) as a set.
  text_guard.py --snapshot OUT.json   record the current strings
  text_guard.py --check OUT.json      compare: exit 1 if any string was added, removed or reworded
Moving a string to another place is fine (it's a set); changing or dropping it is not.
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2] / "Sources" / "MacroClicker"
LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

def strings():
    found = {}
    for f in sorted(ROOT.rglob("*.swift")):
        for line in f.read_text().splitlines():
            code = line.split("//")[0] if '"' not in line.split("//")[0] or line.strip().startswith("//") is False else line
            for m in LIT.finditer(code):
                s = m.group(1)
                # Only things a person could read: has a letter and a space or is a capitalized word.
                if re.search(r"[A-Za-z]", s) and (" " in s or s[:1].isupper()):
                    found.setdefault(s, f.name)
    return found

if __name__ == "__main__":
    mode, path = sys.argv[1], pathlib.Path(sys.argv[2])
    now = strings()
    if mode == "--snapshot":
        path.write_text(json.dumps(now, indent=1, sort_keys=True))
        print(f"recorded {len(now)} strings")
    else:
        before = json.loads(path.read_text())
        added = sorted(set(now) - set(before))
        removed = sorted(set(before) - set(now))
        for s in removed: print(f"REMOVED  [{before[s]}] {s}")
        for s in added: print(f"ADDED    [{now[s]}] {s}")
        print(f"{len(now)} strings now, {len(before)} before: {len(added)} added, {len(removed)} removed")
        sys.exit(1 if (added or removed) else 0)
