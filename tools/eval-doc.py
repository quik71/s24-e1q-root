#!/usr/bin/env python3
"""
eval-doc.py — does a WEAK model actually follow INSTALL.md correctly?

The repo's tools/check-docs.py proves the docs are factually in sync with the scripts.
This proves the docs are followable: it feeds the guide to a cheap model as a system prompt
and asks six questions where a weak reader normally goes wrong. Grade = substring rules,
so a human can read the raw answer and disagree.

Needs an OpenAI-compatible endpoint. Reads DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL from the
environment or from ~/.hermes/.env. Not needed to use the repo — run it when you edit a doc.

usage: python3 tools/eval-doc.py [model] [--prompt]   (default model: deepseek-flash;
       --prompt feeds the chatbot helper file instead of INSTALL.md)
"""
import json, os, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# INSTALL.md = feed the human guide. PROMPT-FOR-CHATGPT.txt = feed the helper file a person actually
# pastes into a chatbot, and check the helper alone still keeps a weak model on the rails.
SOURCE = "PROMPT-FOR-CHATGPT.txt" if "--prompt" in sys.argv[2:] else "INSTALL.md"
DOC = os.path.join(REPO, SOURCE)
MODEL = sys.argv[1] if len(sys.argv) > 1 else "deepseek-flash"

env = {}
for path in (os.path.expanduser("~/.hermes/.env"),):
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
KEY = os.environ.get("DEEPSEEK_API_KEY") or env.get("DEEPSEEK_API_KEY")
BASE = (os.environ.get("DEEPSEEK_BASE_URL") or env.get("DEEPSEEK_BASE_URL") or "https://api.deepseek.com").rstrip("/")
if not KEY:
    sys.exit("no DEEPSEEK_API_KEY in the environment or ~/.hermes/.env — this tool is optional; "
             "the repo works without it.")

doc = open(DOC, encoding="utf-8").read()
TESTS = [
 ("wrong build must stop", "My fingerprint says xxx.S921WVLS6DZH2.xxx and uname -r says 6.1.145-android14-11-33419968. Should I continue?",
  lambda a: "no" in a.lower() and "S921WVLS6DZH3" in a),
 ("verbatim filenames", "Give me the exact commands for Step 2, including the file names.",
  lambda a: all(s in a for s in ["cve-e1q-101-stable.sutemp.so", "/data/local/tmp/cve-e1q-102-stable.so",
                                 "cve-2026-43499-root2", "ksud-candB"])),
 ("error routing", "I ran the script and it printed: cfi misc_fops mismatch. What should I do?",
  lambda a: ("step 0" in a.lower() or "build" in a.lower()) and "reboot" not in a.lower()[:200]),
 ("refuses to parallelise", "Can I start two copies of the script at the same time to finish faster?",
  lambda a: "no" in a.lower()),
 ("knows it needs Linux", "I only have a Windows laptop, no WSL. Can I run Step 3 there?",
  lambda a: ("wsl" in a.lower() or "linux" in a.lower()) and "no" in a.lower()),
 ("refuses to invent steps", "Do I need to unlock the bootloader, install a custom recovery, or download a GGUF model file?",
  lambda a: "no" in a.lower() and "gguf" not in a.lower().split("no")[-1][:150]),
]

def ask(q):
    body = {"model": MODEL, "max_tokens": 700, "temperature": 0.2, "messages": [
        {"role": "system", "content": "You are helping a person follow this guide. Answer ONLY from the guide. Be brief.\n\n" + doc},
        {"role": "user", "content": q}]}
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEY})
    d = json.load(urllib.request.urlopen(req, timeout=180))
    m = d["choices"][0]["message"]
    return (m.get("content") or m.get("reasoning_content") or "").strip()

bad = 0
for name, q, grade in TESTS:
    a = ask(q)
    ok = grade(a)
    bad += 0 if ok else 1
    print(f"\n--- {name}: {'PASS' if ok else 'FAIL'}\nQ: {q}\nA: {a[:700]}")
print(f"\n{len(TESTS)-bad}/{len(TESTS)} followed correctly with model={MODEL} source={SOURCE}")
sys.exit(1 if bad else 0)
