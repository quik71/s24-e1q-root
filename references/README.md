# References — S24 Ultra / S24 (SM8650) targets

These device profiles are **not** part of the e1q work itself. They are the
targets we looked at first, and they are where the e1q port got its start.

## Why they matter

The e1q / SM-S921W port began from a single observation, recorded in the
master hand-off:

> The e1q (S921W) and the e3q (S928B, S24 Ultra) devices are the **same
> SM8650 SoC on the same kernel build** (`6.1.145-android14-11-33419968`).
> The upstream KernelSU module built for e3q audits symbol-clean against the
> e1q target, so e1q root may need no kernel build at all — just a working
> loader.

That meant the S24 Ultra was the reference device for the whole approach:
the loader, the module, the pipe-budget exploit geometry, the DEFEX
bind-mount trick, and the `--allow-shell` late-load. The e1q work is a
port of that path onto a locked-bootloader S24.

## What is here

| Profile | Device | Notes |
| --- | --- | --- |
| `e3q-S9280ZCS6DZF2` | S24 Ultra China `SM-S9280` | The loader that actually works on e1q (`ksud-e3q-S9280ZCS6DZF2-kdp`) |
| `e3q-S928BXXS6DZF2` | S24 Ultra intl `SM-S928B` | Audited symbol-clean against e1q |
| `e3q-S928USQS6DZF2` | S24 Ultra US `SM-S928U1` | **Does not work** — patches `sys_call_table`, RKP resets the phone |
| `e1s-S921BXXSFDZE1` | S24 `SM-S921B` | Same SM8650 family |
| `e1s-S921BXXSFDZF2` | S24 `SM-S921B` | Same SM8650 family |
| `e1s-S921NKSSFDZF3` | S24 `SM-S921N` | Same SM8650 family |
| `e2s-S926BXXUEDZDR` | S24+ `SM-S926B` | Same SM8650 family |

These are upstream Root-My-Galaxy target profiles, kept here for
reproducibility and to document the decision trail. See
[`../README.md`](../README.md) for the e1q work.
