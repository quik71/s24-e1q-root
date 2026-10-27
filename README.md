# e1q / Galaxy S24 (SM-S921W) — exploit root + KernelSU + unattended re-root

Exploit root, a late-loaded KernelSU module, and the automation that keeps a **locked-bootloader**
Galaxy S24 (codename `e1q`, build `S921WVLS6DZH3`) rooted after every reboot — with nobody touching
anything, as long as the phone stays plugged into the host.

**Verified end-to-end 2026-10-02.** The phone boots, comes back unrooted, and the host re-establishes
root in ~12 minutes, unattended.

---

## Why this exists

The bootloader is **locked** (`ro.boot.verifiedbootstate=green`, `ro.boot.flash.locked=1`). So:

- No flashing a modified boot image → no baked-in KernelSU → no on-disk persistence.
- The exploit is an **in-RAM kernel bug** (`pipe physrw` on the uid-2000 page budget). RAM-only.
- KernelSU here is a **late-loaded LKM** — a kernel module loaded into the running kernel, not baked
  into any partition. Also RAM-only.

A reboot erases both. What *can* be automatic is **re-establishment**: a watcher notices the phone
came back without root and runs the proven procedure. That's the whole job, and it works.

> True persistence (KernelSU baked into the boot image) *is* reachable if the bootloader is ever
> unlocked — see "Flashing / persistence" below. It costs a factory reset + the Knox fuse, and the
> OEM-unlock toggle is not exposed on this variant.

## Origin — where this port started

The e1q / SM-S921W port began from one observation, recorded in the master
hand-off: the e1q (S921W) and the e3q (S928B, S24 Ultra) devices are the
**same SM8650 SoC on the same kernel build** (`6.1.145-android14-11-33419968`).
The upstream KernelSU module built for e3q audits symbol-clean against the e1q
target — so e1q root may need no kernel build at all, just a working loader.

That made the S24 Ultra the reference device for the whole approach: the
loader, the module, the pipe-budget exploit geometry, the DEFEX bind-mount
trick, and the `--allow-shell` late-load. The e1q work is a port of that path
onto a locked-bootloader S24. The upstream S24 Ultra (e3q) target profiles we
looked at first are kept in [`references/`](references/) for reproducibility and
to document the decision trail.

---

## Directory layout

```
src/                     CVE-2026-43499 exploit source + our e1q port (targets/)
backups/                 Proven build artifacts (the helper + preload that delivered root)
kernelsu/                The one KernelSU loader that works on this device
native-module/           Our own native e1q kernelsu.ko + the GKI build script
scripts/                 solid_root.sh (the procedure), phone_autoroot.sh (the watcher), the unit
tools/check-docs.py      machine-checks the user docs (paths, md5s, promised output, paste safety)
INSTALL.md               THE SHORT VERSION — start here if you just want your phone rooted
firmware/                boot.img for this device (the patch target for the persistence route)
docs/                    The full handoff write-up (read this first)
```

---

## How to use it

> If you just want your phone rooted and don't care how, read **[INSTALL.md](INSTALL.md)** instead.
> It is written for a first-time reader **and** for a chatbot reading it to one — it has a glossary,
> literal expected output for every command, and an exact-words error table. Keep both files honest by
> running `python3 tools/check-docs.py` before you commit a change to either.

### 0. Check your device matches before anything else

This port is for **SM-S921W on firmware build `S921WVLS6DZH3`**, kernel
`6.1.145-android14-11-33419968`. A profile matches a device on **exact SoC + kernel + firmware
build** — the same phone on a newer update has different symbol offsets and the exploit will not
land. Check before you spend an afternoon:

```bash
adb shell getprop ro.product.model       # SM-S921W
adb shell getprop ro.build.fingerprint   # must contain S921WVLS6DZH3
adb shell uname -r                       # 6.1.145-android14-11-33419968
```

Other SM8650 targets we audited are kept in [`references/`](references/) — they are *not*
interchangeable with this one.

### 1. Put the three files on the phone (one time)

They must live in `/data/local/tmp`. `/sdcard` is outside the dynamic loader's namespace and gives a
misleading `CANNOT LINK EXECUTABLE … is not accessible for the namespace`.

```bash
adb push backups/cve-e1q-101-stable.sutemp.so /data/local/tmp/cve-e1q-102-stable.so
adb push backups/cve-2026-43499-root.sutemp   /data/local/tmp/cve-2026-43499-root2
adb push kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp  /data/local/tmp/ksud-candB
adb shell chmod 755 /data/local/tmp/cve-e1q-102-stable.so /data/local/tmp/cve-2026-43499-root2 /data/local/tmp/ksud-candB
```

Use the **`.sutemp`** pair (socket-renamed). The `.proven` pair is the original, kept for the
rollback; if you use it instead, export `SOLID_PRELOAD`/`SOLID_HELPER` to those paths. Never load any
loader except `ksud-e3q-S9280ZCS6DZF2-kdp` — see "The loader matters" below.

### 2. Per boot — one command

```bash
bash scripts/solid_root.sh 8          # 8 = max boots to grind if there is no live root
```

The script is location-independent: it works from any clone, and writes its logs under `logs/host/`
inside the repo. It:

1. Exits immediately if `su -c id` already returns `uid=0`.
2. Otherwise grinds: reboot → wait for boot → up to 10 attempts per boot, up to N boots. A reboot is
   forced after 3 consecutive dead attempts. **It reboots the phone by itself; that is normal.**
3. Installs the persistent userspace (`/data/adb/ksud`) if missing.
4. Bind-mounts the loader over `/system/bin/logcat` (DEFEX only permits privileged exec from a system
   path) and loads the module with `--allow-shell`.
5. Verifies `su -c id` → `uid=0` in `u:r:ksu:s0`, then deletes the channel sockets with real root.

Attempts are probabilistic (an allocator race): roughly 1 in 2–10 wins, and **only one attempt may run
at a time** — concurrent attempts share one per-uid pipe-page budget and both die. The script enforces
this with an `flock`; do not work around it.

### 3. Keep it rooted across reboots — the watcher

Two edits first, because the files were written for our server: set `WORK=` in
`scripts/phone_autoroot.sh` to your clone, and set `User=` in `scripts/phone-autoroot.service` to your
username.

```bash
sudo cp scripts/phone_autoroot.sh /usr/local/sbin/
sudo cp scripts/phone-autoroot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now phone-autoroot
journalctl -f -u phone-autoroot
```

The watcher runs every 20 s: if a device is present and not rooted, it runs `solid_root.sh 8`.
**Stop it before unplugging the phone** — a failed run retries for up to 8 boots:

```bash
sudo systemctl stop phone-autoroot     # pause
```

### 4. Verify a rooted phone

```bash
adb shell "su -c id; getenforce; grep kernelsu /proc/modules"
# uid=0(root) ... context=u:r:ksu:s0
# Enforcing
# kernelsu 212992 0 - Live 0x0000000000000000 (O)
```

If `su` says `connect daemon: Permission denied`, a poisoned socket survived the reboot: delete
`/data/local/tmp/temp_su.sock` and `/data/local/tmp/su_temp.sock` (with real root if you still have
it) and reboot once.

---

## The three non-obvious facts

1. **`--allow-shell` is load-time only.** `allow_shell` is a KernelSU module param with no sysfs
   knob. Load the module without it and shell gets no root for the entire boot.
2. **DEFEX kills privileged exec outside a system partition.** The loader is bind-mounted over
   `/system/bin/logcat` and run from there.
3. **A poisoned socket inode silently breaks the root channel.** The socket path is baked into the
   binary; a stale one (stat/connect/unlink all denied) makes real kernel wins invisible. The shipped
   pair uses a renamed channel and deletes the sockets with real root at the end.

Details are in `docs/HANDOFF-2026-10-02-MASTER-e1q-root-kernelsu-autoroot.md`.

---

## The loader matters — one of them resets the phone

Use **only** `ksud-e3q-S9280ZCS6DZF2-kdp` (md5 `939a2f454946baf9de4409d16c5a2180`). The S928U
loader patches `sys_call_table` and Samsung RKP resets the phone instantly. Never load candidate A.

---

## Flashing / persistence (if the bootloader is ever unlocked)

Persistent root needs an unlocked bootloader → a patched boot image → flashing. The chain is:

```
persistent root ← modified boot image ← flashing ← unlocked bootloader ← OEM-unlock toggle
```

If the OEM-unlock toggle is **absent** (not exposed on this North-American variant), the flashing
route is dead and the watcher is the answer. If it is present and usable, you can:

1. Unlock (accept: full factory reset + Knox fuse `0 → 1`, permanently).
2. Patch `firmware/boot.img` with KernelSU (GKI 2.0 → kernel lives in `init_boot` on this device).
3. Patch `vbmeta` to disable verification/verity.
4. Flash with Odin using the **same build**, keep the stock BL.

`firmware/boot.img` is already extracted and included. Note: unlocking blows the Knox fuse one-way
(kills Wallet, Secure Folder, some banking/DRM). Current state on the phone: `ro.boot.warranty_bit=0`
(Knox intact).

---

## Attribution

The exploit (CVE-2026-43499) is based on the source published at
<https://github.com/NebuSec/CyberMeowfia/tree/main/IonStack/CVE-2026-43499/exploit>.

The KernelSU port is based on <https://github.com/tiann/KernelSU> (v3.2.5).

This work is a device-specific port + automation layer on top of both.

---

## Warning

This is a kernel memory-corruption exploit on a daily phone. Repeated use has not caused persistent
damage in these runs, but it is still an exploit. Back up the phone, and pause the watcher if you
don't need root.

Use only on devices you own or are explicitly authorized to test.
