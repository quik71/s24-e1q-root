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
firmware/                boot.img for this device (the patch target for the persistence route)
docs/                    The full handoff write-up (read this first)
```

---

## How to use it

### Per boot — one command

```bash
cd /srv/storage/work/s24-root-payloads-2026-09-30
bash solid_root.sh 8          # 8 = max boots to grind if there is no live root
```

The procedure:

1. If `su -c id` already returns `uid=0`, exit immediately.
2. Otherwise grind: reboot → wait for boot → up to 10 attempts per boot, up to N boots. A reboot is
   forced after 3 consecutive dead attempts.
3. Install the persistent userspace (`/data/adb/ksud`) if missing.
4. Bind-mount the loader over `/system/bin/logcat` (DEFEX only permits privileged exec from a system
   path) and load the module with `--allow-shell`.
5. Verify `su -c id` → `uid=0` in `u:r:ksu:s0`, then delete the channel sockets with real root.

### Keep it rooted across reboots — the watcher

```bash
sudo systemctl start phone-autoroot.service     # resume
sudo systemctl stop  phone-autoroot.service     # pause (e.g. phone off for the day)
tail -f logs/phone-autoroot.log
```

The watcher (`phone_autoroot.sh`) runs every 20 s: if a device is present and not rooted, it runs
`solid_root.sh 8`. It is installed as `phone-autoroot.service` (enabled + active) on the host.
**Pause it before unplugging the phone** — a failed run retries for up to 8 boots.

### Verify a rooted phone

```bash
adb shell "su -c 'id; getenforce; grep kernelsu /proc/modules'"
# uid=0(root) ... context=u:r:ksu:s0
# Enforcing
# kernelsu 212992 0 - Live 0x0000000000000000 (O)
```

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
