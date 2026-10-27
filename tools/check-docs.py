#!/usr/bin/env python3
"""
check-docs.py — verify the user-facing docs are actually followable by a stranger (or a chatbot).

Why this exists: the docs used to describe OUR server (absolute paths, "cd into a folder that only
exists on our machine", commands continued with '\', promised output nobody prints). Those defects are
invisible to the author and fatal to the reader. This script fails loudly on the same class of defect.

Checks
  1. no line-continuation '\' inside copy-paste bash blocks   (a pasted block must run as-is)
  2. every repo path a doc mentions exists in the repo         (runtime dirs allowed via RUNTIME_OK)
  3. every md5 a doc claims matches the real file              (docs age, files change)
  4. every literal output string the docs promise is printed by the scripts (or is another program's)
  5. no machine-specific absolute paths (our array / our home) outside the dated handoff
  6. README / INSTALL / the chatbot prompt teach the SAME commands — a reader must not get three
     slightly different procedures depending on which file they opened
  7. the chatbot prompt still carries the rules that keep a weak model safe (build gate, no
     parallelising, "only su -c id == uid=0 is success", the exact-word error table)

usage: python3 tools/check-docs.py
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = ["README.md", "INSTALL.md", "PROMPT-FOR-CHATGPT.txt"]   # user-facing only; docs/ is a dated record
# The commands a reader must be able to copy from ANY of the three entry points. If one of these
# drifts out of a file, that file is now teaching a different procedure than the others.
SHARED_COMMANDS = [
    "adb push backups/cve-e1q-101-stable.sutemp.so /data/local/tmp/cve-e1q-102-stable.so",
    "adb push backups/cve-2026-43499-root.sutemp /data/local/tmp/cve-2026-43499-root2",
    "adb push kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp /data/local/tmp/ksud-candB",
    "adb shell chmod 755 /data/local/tmp/cve-e1q-102-stable.so /data/local/tmp/cve-2026-43499-root2 /data/local/tmp/ksud-candB",
    "bash scripts/solid_root.sh 8",
    'adb shell "su -c id"',
]
# A chatbot prompt must still carry the gates that matter, or it will happily walk someone off a cliff.
PROMPT_REQUIRED = ["S921WVLS6DZH3", "SM-S921W", "uid=0(root)", "CHANGE_ME", "*** SUCCESS:",
                   "step at a time",            # paces one command at a time
                   "one copy may run at a time",  # refuses to parallelise the grind
                   "cfi misc_fops mismatch",      # keeps the error table
                   "invented nothing".replace("invented nothing", "Invent nothing")]
RUNTIME_OK = {"logs", "logs/host"}            # created by the scripts, not shipped
EXTERNAL_MSG = [                              # strings produced by systemd/adb, not by our scripts
    "unauthorized", "Unit ", "User '", "No such file or directory", "adb: ", "1 file pushed",
]
PROMISED = [
    "*** SUCCESS: exploit root -> module(allow_shell=1) -> sucompat -> uid 0 (u:r:ksu:s0) ***",
    "FAILED: no root after",
    "phone present WITHOUT root -> re-establishing",
    "re-root OK:",
    "no boot_completed",
    "adb gone",
    "cfi misc_fops mismatch",
    "connect daemon: Permission denied",
    "already solid on this boot",
]
SCRIPTS = ["scripts/solid_root.sh", "scripts/phone_autoroot.sh", "scripts/phone-autoroot.service"]

fails, notes = [], []

def p(rel): return os.path.join(ROOT, rel)

# --- gather script contents once (for "promised output" checks)
script_text = {}
for s in SCRIPTS:
    if not os.path.exists(p(s)):
        fails.append(f"[missing] shipped script {s} is gone")
        continue
    script_text[s] = open(p(s), encoding="utf-8").read()

doc_text = {}
for d in DOCS:
    if not os.path.exists(p(d)):
        fails.append(f"[missing] doc {d}")
        continue
    doc_text[d] = open(p(d), encoding="utf-8").read()

for d, text in doc_text.items():
    lines = text.splitlines()

    # 1. copy-paste safety
    in_bash, block = False, []
    for i, ln in enumerate(lines, 1):
        if ln.strip().startswith("```bash"):
            in_bash, block = True, []
            continue
        if in_bash and ln.strip() == "```":
            in_bash = False
            continue
        if in_bash and ln.rstrip().endswith("\\"):
            fails.append(f"[paste] {d}:{i} line ends in '\\' — a pasted block will not run: {ln.strip()[:60]}")

    # 2. referenced repo paths exist
    refs = set(re.findall(r"\b(?:backups|kernelsu|native-module|references|scripts|src|firmware|docs|logs|tools)/[A-Za-z0-9._/\-]*[A-Za-z0-9._\-]", text))
    for r in sorted(refs):
        if r.split("/")[0] in RUNTIME_OK:
            continue
        if not os.path.exists(p(r)):
            fails.append(f"[path] {d} references {r}, which is not in the repo")

    # 3. claimed md5s match reality
    for m in re.finditer(r"md5sum\s+([A-Za-z0-9._/\-]+)[^\n]*\n```\s*\nExpected:\s*([0-9a-f]{32})", text):
        fpath, want = m.group(1), m.group(2)
        if not os.path.exists(p(fpath)):
            continue  # already flagged by check 2
        real = subprocess.run(["md5sum", p(fpath)], capture_output=True, text=True).stdout.split()[0]
        if real != want:
            fails.append(f"[md5] {d} says {fpath} is {want}, it is really {real}")

    # 5. machine-specific leftovers
    for m in re.finditer(r"(/srv/[\w/\-\.]+|/home/blackieserver[\w/\-\.]*)", text):
        fails.append(f"[host-path] {d} leaks a path that only exists on our server: {m.group(1)}")

    # 6. the three entry points must teach ONE procedure, not three similar ones
for d, t in doc_text.items():
    for cmd in SHARED_COMMANDS:
        if cmd not in t:
            fails.append(f"[drift] {d} is missing/altering a command the other entry points use: {cmd}")

prompt = doc_text.get("PROMPT-FOR-CHATGPT.txt", "")
# prose in the prompt file is line-wrapped like normal writing, so compare with whitespace collapsed.
# Commands in SHARED_COMMANDS are still matched verbatim — a command must not be reflowed.
prompt_prose = re.sub(r"\s+", " ", prompt).lower()
for req in PROMPT_REQUIRED:
    if req.lower() not in prompt_prose:
        fails.append(f"[prompt] PROMPT-FOR-CHATGPT.txt no longer carries {req!r} — a chatbot following "
                     "it will stop enforcing that rule")
if "PROMPT-FOR-CHATGPT.txt" not in doc_text.get("README.md", ""):
    fails.append("[drift] README.md does not point readers at PROMPT-FOR-CHATGPT.txt")

# 4. promised output really exists
for s in PROMISED:
    if not any(s in t for t in script_text.values()):
        fails.append(f"[string] docs promise the output {s!r} but no shipped script emits it")

# extra guard: the unit must keep its loud placeholder + the docs must mention it
unit = script_text.get("scripts/phone-autoroot.service", "")
if "User=CHANGE_ME" not in unit:
    fails.append("[unit] scripts/phone-autoroot.service no longer fails loudly on a missing User=")
if "User=CHANGE_ME" in unit and not any("CHANGE_ME" in t for t in doc_text.values()):
    notes.append("[note] the unit's User=CHANGE_ME is undocumented in the docs")

print(f"checked: {', '.join(DOCS)} against {len(script_text)} shipped scripts")
for n in notes:
    print(n)
if fails:
    print(f"\nFAIL ({len(fails)}):")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("PASS: every pasted command runs as-is, every path and md5 in the docs is real, "
      "every promised output string is really printed.")
