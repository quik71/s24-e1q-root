# MASTER HANDOFF — e1q / Galaxy S24 (SM-S921W): exploit root + KernelSU + unattended re-root

**Written:** 2026-10-02 (PDT) by TED, for Mike.
**Status: WORKING AND VERIFIED END-TO-END.** Read §1 first, then §3 if you just want to operate it,
then §5 if something breaks.

Companion files (same directory) — read them for the blow-by-blow history if this document is not enough:

| File | What it holds |
| --- | --- |
| `HANDOFF-2026-10-02-kernelsu-plan.md` | The living build log for this whole effort, §1–§12, including the native e1q module build and every loader/CFI experiment |
| `HANDOFF-2026-10-01-root-achieved-but-probabilistic.md` | The first root, and the "why is it probabilistic" question |
| `HANDOFF-2026-10-02-root-was-live-and-pipe-budget-diagnosis.md` | Pipe-budget arithmetic, CFI trace |
| `HANDOFF-2026-10-01-stable-reaches-cfi-fails-pirw.md`, `HANDOFF-2026-10-01-gate-fixes-and-stable-blocked.md`, `HANDOFF-timerfd-fix-confirmed-working.md`, `HANDOFF-pselect-sched_setattr-2026-09-28.md` | The exploit-reachability work (before root was ever achieved) |
| `HANDOFF-2026-09-30.md`, `HANDOFF-2026-09-30-202x.md` | Survey of the payload tree, profiles, gates |

---

## 1. Executive summary — what is true right now

* **The phone is rooted, right now, via KernelSU.** `su` works, SELinux is Enforcing, the module is loaded:
  ```
  $ adb shell "su -c 'id; getenforce; grep kernelsu /proc/modules'"
  uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
  Enforcing
  kernelsu 212992 0 - Live 0x0000000000000000 (O)
  ```
* **Root is re-established automatically after every reboot**, with nobody touching anything, as long as the
  phone stays on the USB cable to blackie. Verified: reboot issued 09:10:23, `su` working again 09:22:22 —
  **12 minutes, zero intervention** (watcher detected the unrooted boot 27 s after it came up).
* **This is re-establishment, NOT persistence.** It cannot be persistence: the bootloader is locked
  (`ro.boot.verifiedbootstate=green`), so the boot image can never be modified and KernelSU can never be baked
  in. KernelSU here is a **late-loaded LKM** — a RAM-only kernel module. The exploit is a RAM-only kernel bug.
  The exploit author's own docs say the same: *"Locked bootloader; no persistent boot.img modification.
  Re-establish per boot."* and *"Both temp root and KSU are per-boot"* (`docs/SM-S9360-…md:4,174`), with only
  `/data/adb/ksu` surviving (`docs/SM-S9360-…md:177`).
* **What holds the state up:**
  1. `phone-autoroot.service` on blackie (systemd, **enabled + active**) → runs the watcher → runs the
     procedure whenever the phone is present without root.
  2. `/data/adb/ksud` on the phone (persistent) → KernelSU's userspace side, required for `su` to exist.
  3. The payload pair on the phone (persistent) → helper + preload that talk over a socket channel.
* **The three non-obvious facts that took boots to learn** (details in §5):
  1. KernelSU's late-load must be given **`--allow-shell`**; `allow_shell` is a load-time module param with no
     sysfs knob, and without it `su` can never work for shell on that boot.
  2. **DEFEX** kills any privileged exec whose path is not in a system partition, so the loader is bind-mounted
     over `/system/bin/logcat` and run from there.
  3. A **poisoned socket inode** (`/data/local/tmp/temp_su.sock`, stat/connect/unlink all denied) silently
     breaks the exploit's root channel across every later boot, making real in-kernel wins invisible. Fixed by
     binary-patching the proven payloads onto a fresh socket name, and by deleting the socket with real root at
     the end of every successful chain.

---

## 2. Target, host, and environment (exact)

### 2.1 Phone

| Item | Value |
| --- | --- |
| Model | Galaxy S24, `SM-S921W` (Canada) |
| Device codename | `e1q` |
| Build / firmware | `e1q-S921WVLS6DZH3` |
| Android / kernel | `BP4A.251205.006`, kernel `6.1.145-android14-11-33419968-abS921USQS6DZH3` |
| SoC | Snapdragon 8 Gen 3 (SM8650) |
| vmlinux build ID | `33419968` |
| Bootloader | **LOCKED** (`ro.boot.verifiedbootstate=green`) — no flashing, no boot.img patching, no BL unlock |
| Kernel config facts that matter | `MODULE_SIG=y` but `MODULE_SIG_FORCE` unset; `RKP=y`; `CFI_CLANG=y`; clang `r487747c`; `CONFIG_DEBUG_INFO_BTF=y` |
| SELinux while rooted | **Enforcing** (su still works because KernelSU handles it) |
| `su` context when working | `u:r:ksu:s0` (KernelSU's own domain) |
| Root context before KernelSU | `u:r:kernel:s0` (exploit daemon runs in the kernel domain) |
| Exploit root daemon cmdline | `cve-2026-43499-root --umh 2000` (uid 0), serving uid 2000 clients |

### 2.2 Host (blackie)

| Item | Value |
| --- | --- |
| Work tree | `/srv/storage/work/s24-root-payloads-2026-09-30` (git-tracked; upstream = the payloads repo) |
| Kernel-build tree | `/srv/storage/work/e1q-kernelsu/` (sm8650 source, KernelSU v3.2.5, clang `r487747c`, `venv`, `buildlogs/`) |
| adb transport | **USB**: `usb:1-6`, serial `R3CXA0G3RAR`, `product:e1qcsx model:SM_S921W` — the phone must stay plugged in |
| adb server owner | user `blackieserver` (the watcher must run as this same user, never root — two adb servers fight over the device and port 5037) |
| NDK | `/tmp/android-ndk-r27c` (note: `/tmp` — will not survive a reboot of blackie; re-download if you need to rebuild) |
| sudo | passwordless for `install`, `systemctl`, `loginctl` — `sudo loginctl enable-linger` does NOT work (needs a terminal) |

---

## 3. The procedure — how to operate this

### 3.1 Per boot: one command

```bash
cd /srv/storage/work/s24-root-payloads-2026-09-30
bash solid_root.sh 8          # 8 = max boots to grind if there is no live root
```

What it does, in order, with the reasoning inline:

1. **Phase 0** — if `su -c id` already returns `uid=0`, exit immediately and touch nothing.
2. **Phase 1** — take the global lock (`/tmp/solid_root.lock`, `flock`), clear any stale socket path, then
   either use the live root or **grind**: reboot → wait for `sys.boot_completed` → wait for quiet (`uptime≥130`)
   → up to 10 serial attempts per boot → up to 8 boots. A reboot is forced after 3 consecutive "dead" attempts
   (attempts that never reach the verification stage).
3. **Phase 2** — as root, install userspace if missing: `/data/adb/ksud` + `/data/adb/ksu/bin/ksud`
   (= `KSUD_PATH`; see §5.4). Idempotent, and persistent across reboots.
4. **Phase 3** — **load the module with `--allow-shell`**, run from a system path:
   ```bash
   mount --bind /data/adb/ksud /system/bin/logcat      # DEFEX only permits exec from a system partition
   /system/bin/logcat late-load --allow-shell --ephemeral --kmi android14-6.1
   ```
   Candidate shadow targets, in order: `/system/bin/logcat`, `/system/bin/atrace`, `/system/bin/dumpstate`,
   `/system/bin/abx2xml`.
5. **Phase 4** — verify: `grep kernelsu /proc/modules` and `su -c id` must show `uid=0` + `u:r:ksu:s0`; then
   **delete the channel sockets with real root** (`su -c 'rm -f /data/local/tmp/temp_su.sock /data/local/tmp/su_temp.sock'`)
   so no poisoned inode can be inherited by the next boot.

### 3.2 To use a specific payload pair (env overrides)

```bash
SOLID_HELPER=/data/local/tmp/cve-2026-43499-root2 \
SOLID_PRELOAD=/data/local/tmp/cve-e1q-102-stable.so \
bash solid_root.sh 8
```
These are exactly what `phone-autoroot.service` passes (see §7).

### 3.3 A single manual attempt (what the grind does per attempt)

```bash
H=/data/local/tmp/cve-2026-43499-root2          # helper
SO=/data/local/tmp/cve-e1q-102-stable.so        # preload payload
D=/data/local/tmp/solid/bXaY ; mkdir -p $D ; : > $D/gate.txt
adb shell "setsid sh -c 'EXPLOIT_ATTEMPTS=1 P0_GATE_SLOT_INDEX=0 CVE43499_ROOT_HELPER=$H LD_PRELOAD=$SO \
  nohup sleep 3600 > $D/gate.txt 2>&1' </dev/null >/dev/null 2>&1 &"
sleep ~12 ; adb shell "tail -c 3000 $D/gate.txt"        # watch for the stages
adb shell "$H -c 'id'"                                   # the root check: uid=0 means the daemon is serving
```
* `P0_GATE_SLOT_INDEX=0` is the **only** viable geometry found; `slot8` breaks reclaim, a 60 ms stack-writer
  delay is identical to baseline, `slot0+load6` reaches no signature. Do not re-sweep these.
* Exploit env knobs available: `EXPLOIT_ATTEMPTS`, `P0_GATE_SLOT_INDEX`, `CVE43499_ROOT_HELPER`, `LD_PRELOAD`,
  `STACK_WRITER_DELAY_USEC`, `FINE_TICKS_OVERRIDE`, `PSELECT_DELAY_USEC`. Helper also takes `-c '<cmd>'` and
  `--late-load`.
* **Never overlap attempts** (the lock enforces this). One attempt burns ~15360 of the uid-2000 pipe budget.
* **Never `timeout -s KILL`** an attempt: a KILLed run once left a forked root daemon alive for 8 hours. The
  serial discipline and clean shutdown matter.

### 3.4 Verify a rooted phone

```bash
adb shell "su -c 'id; getenforce; grep kernelsu /proc/modules'"
adb shell "su -c 'dmesg | grep -iE \"su found|su->ksud|KDP task-scoped\" | tail -5'"   # sucompat working
adb shell "su -c 'rm -f /data/local/tmp/temp_su.sock'"                                 # keep the channel clean
```

---

## 4. How the chain actually works (so you can debug it)

```
 [1] exploit attempt (uid 2000, LD_PRELOAD payload)
        │  kernel bug → physical R/W → patch creds: uid 2000 → 0        ("pipe physrw ... uid=2000->0")
        ▼
 [2] root daemon (uid 0, u:r:kernel:s0) listens on a UNIX socket
        │  path: /data/local/tmp/su_temp.sock   (BOOTSTRAP_SOCK_PATH in su_daemon.c)
        │  client uid allowlisted (allowed_client_uid)
        ▼
 [3] helper client: cve-2026-43499-root -c '<cmd>'   → runs <cmd> as root
        │  this is the ONLY root channel; the log calls it "bootstrap socket remains authoritative"
        ▼
 [4] ksud (the payload's userspace loader) is exec'd — but DEFEX only allows exec from a system path,
        │  so we bind-mount ksud over /system/bin/logcat and exec that
        ▼
 [5] ksud late-load --allow-shell --ephemeral --kmi android14-6.1
        │  loads its embedded KernelSU module INTO THE RUNNING KERNEL (LKM, RAM only)
        │  allow_shell=1 ⇒ policy/allowlist.c auto-allows SHELL_UID(2000) ⇒ shell may use su
        ▼
 [6] KernelSU module init: Samsung KDP/DEFEX credential handling, syscall hook,
        │  path hiding (that's why /data/adb looks "Permission denied" to shell afterwards)
        ▼
 [7] sucompat: exec("/system/bin/su") by an allowed uid →
        │  stat/access of "su" redirected to KSUD_PATH=/data/adb/ksud,
        │  execve redirected to ksud + escape_with_root_profile() ⇒ uid 0 in u:r:ksu:s0
        ▼
 [8] su works.  NOTE: step 5 kills step [3] — the root bridge dies the instant the module initialises,
        so every root-only prep step MUST happen before the load.
```

**Volatility map**

| Thing | Survives reboot? |
| --- | --- |
| Exploit root (daemon/socket) | No |
| KernelSU module (late-loaded LKM) | No |
| `/data/adb/ksud`, `/data/adb/ksu/**` | **Yes** (persistent) |
| The staged payloads in `/data/local/tmp` | **Yes** (persistent — and that is how the poisoning bit us) |
| `/system/bin/logcat` bind mount | No |
| `blackie`'s watcher unit | Yes (systemd, enabled) |

---

## 5. Findings and gotchas (the expensive part — read before changing anything)

### 5.1 Root looked "probabilistic"; it is a pipe-budget lottery

* `pipe-user-pages-soft = 16384` pages (64 MiB) **per uid**; the exploit's footprint is
  `PIPE_BUFFER_SLOTS=32` × `PIPE_RECLAIM=240` × 2 sides ≈ **15360 pages ≈ 94 %** of the budget, by design.
* Consequence: `F_SETPIPE_SZ` → `EPERM` is **budget arithmetic, not dirty state**. Do NOT reboot on EPERM
  (`fs/pipe.c::pipe_set_size()`); wait ~90 s and retry. Reboot only after 3 consecutive *dead* attempts.
* Two attempts at once (any two, from any caller) starve each other → hence the global `flock`.
* A single attempt also has a timing component: the success rate observed is roughly **1 in 2–10 attempts**
  (today: 2, 10, 7, 7 attempts to success across four runs). Budget minutes, not seconds. Attempt ≈ 35–60 s.
* The residual failure signature is CFI, and it is *identical* every time:
  ```
  WRITE-TARGET oracle_target=ffffffc00a56b5b0 … slot_index=0 → slide pi stage=owner-chain-lock-enter
  → cmp-return ret=-1 errno=35 → deadlock-accepted → wait-timeout-accepted → writer-enter
  → writer-return sched_ok=1 window=1 → verifying-kernel-access
  → cfi misc_fops mismatch ret=0 target=ffffffc00a56b5b0 read=0 want=ffffff887e411180
  ```
  The writer's success flag lies (`ret=0`) while the fake-fops write never lands. That is the loss condition;
  it is a per-attempt lottery, so the only lever is more attempts. (Rejected: "one attempt per boot" — the
  refusal in `preload.c:240` is per-process, not per-boot; the real rule is *never overlap*.)

### 5.2 The loader matters: one of them RESETS the phone

* ✅ **`kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp`** (S24 Ultra, China `SM-S9280`) — the one that works. Staged as
  `/data/local/tmp/ksud-candB`, md5 `939a2f454946baf9de4409d16c5a2180`. Also persisted to `/data/adb/ksud`.
* ❌ **`kernelsu/ksud-e3q-S928USQS6DZF2-kdp`** — loads, initialises, then **hard-resets the phone** every time.
  The dead boot's `/proc/last_kmsg` ends mid-line at the exact moment:
  ```
  KernelSU: Samsung DEFEX credential synchronization and KSU-task bypass enabled
  KernelSU: sys_call_table=0xffffffc0091c0cc0  sys_ni_syscall: 0xffffffc008092a64
  KernelSU: ni_syscall 1: 42
  KernelSU: patch syscall 42, 0xffffffc008092a64 -> 0xffffffc02f0d1b90  RAMDUMP BUILD @ …
  ```
  i.e. it wrote the protected `sys_call_table` entry and Samsung **RKP** reset the machine on the spot. The
  S916B reference README says its patch "hard-stops RKP syscall-table writes" — some builds have that
  hard-stop, some don't. **Never load candidate A on this device.**
* Diagnostic trick: `/sys/fs/pstore` is **empty** on this device; the previous boot's kernel log is at
  **`/proc/last_kmsg`** (readable as root) and it is what proves the reset cause.

### 5.3 KernelSU late-load requires `--allow-shell` (load-time only)

```c
// kernel/feature/sucompat.c:171 — the FIRST gate on the su path
if (!ksu_is_allow_uid_for_current(current_uid().val)) goto do_orig_execve;
// kernel/policy/allowlist.c:268, :352
if (unlikely(allow_shell) && uid == SHELL_UID) return true;
// kernel/core/init.c:79-83
bool allow_shell = false;                 // true only with CONFIG_KSU_DEBUG
module_param(allow_shell, bool, 0);       // mode 0 ⇒ NO sysfs entry
```
* Confirmed on device: `/sys/module/kernelsu/parameters/` **does not exist**. `allow_shell` therefore can
  never be changed after load. Load without it and shell gets **no root for the whole boot** — which is exactly
  what happened on the first successful module load (module up, phone alive, `su: inaccessible or not found`).
* `ksud late-load --help` on the working loader confirms the flags:
  `--allow-shell`, `--ephemeral`, `--kmi <KMI>`, `--package-name <PKG>` (default `me.weishu.kernelsu`),
  `--magica [<PORT>]`, `--post-magica`.
* **The exploit helper's own `--late-load` wrapper will NOT do this** — it hardcodes `--ephemeral` and passes
  no `--allow-shell`. That is why we drive ksud ourselves.

### 5.4 `KSUD_PATH` must exist, and it is `/data/adb/ksud`

```c
#define KSUD_PATH "/data/adb/ksud"        // kernel/runtime/ksud.h:6
```
* sucompat **refuses to intercept `su` at all** if that file is missing (`sucompat.c is_ksud_exists()`), and it
  also redirects *stat/access* of "su" to ksud — which is why `su` "exists" even though `/system/bin` is
  read-only erofs and there is no real `su` file on disk.
* Install it (`cp` the loader, `chmod 755`) **before** the module load — afterwards the root bridge is gone.
* `ksud` has **no `su` subcommand** (only `sulogd`); `su` is the kernel-side sucompat + this file.

### 5.5 DEFEX: privileged exec only from a system partition

Symptom: the loader is instantly `Killed`, and dmesg shows
```
[DEFEX] Safeplace violation [task=sh (/system/bin/sh), child=/data/adb/ksud, uid=0]
```
* It is **not** about world-writability. Verified refused: `/data/adb/ksud`, `/dev/ksud`,
  `/data/local/tmp/.ksud-stage`. Only system-partition paths are accepted.
* `/system/bin` is read-only erofs, and **overlayfs is unavailable** on this kernel:
  `mount -t overlay overlay -o lowerdir=/system/bin,… /system/bin` → **`Invalid argument`**.
* Therefore: **bind-mount the loader over an existing system binary and run that path**:
  ```bash
  mount --bind /data/adb/ksud /system/bin/logcat     # bind_rc=0
  /system/bin/logcat late-load --allow-shell --ephemeral --kmi android14-6.1
  ```
  This is exactly what the exploit's own guarded wrapper does — its strings contain `/system/bin/logcat`, and
  the DEFEX violation log named the task `logcat`. Side effect: `logcat` is the loader for the rest of that
  boot (the bind disappears on reboot).
* A `sh` **script** staged at the helper's stage path does *not* work (`/data/adb/ksud` exec from the shim was
  still Killed, and the wrapper produced no output) — use the bind-mount, not a shim.

### 5.6 `--ephemeral` semantics (from ksud's own strings)

> "ephemeral late-load complete; skipping ksud installation and /data/adb" — module only, no userspace install,
> no unload.

Consequence: any userspace we need (`/data/adb/ksud`) must be installed by us, before the load, and only once
(it persists).

### 5.7 The poisoned socket — the bug that hid real roots

* `/data/local/tmp` **persists across reboots**. After the boot in which KernelSU first loaded, the exploit's
  channel socket was left in a state shell cannot touch at all:
  ```
  $ ls -la /data/local/tmp/ | grep sock
  s?????????  ? ?     ?           ?                ? temp_su.sock      # stat denied
  $ rm -f /data/local/tmp/temp_su.sock
  rm: /data/local/tmp/temp_su.sock: Permission denied                 # unlink denied
  ```
  *Inference (not proven):* the KernelSU module's Samsung credential/file handling produced the inode with a
  label/ownership shell cannot use; labels live on the inode, so it survived reboots even with no module loaded.
* Effect: the exploit **won in-kernel on every subsequent boot** and nobody could tell, because the root is
  delivered *through that socket*:
  ```
  [*] src/root.c:615 root p0 reference holder absent after S928 physical handoff; bootstrap socket remains authoritative
  [+] src/main.c:682 pipe physrw pid=31338 done=1 root=1 … rw64=1/1 uid=2000->0
  [+] src/preload.c:234 exploit completed attempt=1/1
  ```
  …while every helper call returned `su: connect daemon: Permission denied` (EACCES). The grind saw "no root"
  23 times in a row and rebooted away genuine wins. **Do not trust "no root" if the socket reports EACCES.**
* **Fix (shipped):** the channel path is baked into three constants — `src/pipe.c:953`, `src/su_daemon.c:27`,
  `src/root.c:10` — and the literal is exactly 28 bytes. Replaced with a same-length name
  (`/data/local/tmp/su_temp.sock`) by **byte-patching the proven binaries** (one occurrence each). Offsets,
  relocations and code are byte-identical afterwards; only the name differs.
* **Belt and braces:** every successful chain now deletes both socket names with real root, so a poison can
  never be inherited again. Verified in the log: `cleanup: ls: /data/local/tmp/temp_su.sock: No such file or directory`.
* Fast triage for this class of bug: `helper -c 'id'` returning **EACCES** = poisoned/stale node;
  returning **ENOENT** = clean channel, just no daemon yet.

### 5.8 Do NOT rebuild the payload to change the socket name

* `make TARGET=e1q-S921WVLS6DZH3 ANDROID_NDK_HOME=/tmp/android-ndk-r27c all stable` produces a
  `cve-2026-43499-app.stable.so` of **112640 B**, whereas the proven artifact is **163840 B** — i.e. today's
  flags are *not* the ones that produced the payload that reaches the CFI stage (the Makefile even
  `truncate -s 112640`s the stable output). A rebuild is a behaviour gamble; the byte-patch is not.
* **The host copy of the proven preload was destroyed by exactly that rebuild** and had to be
  `adb pull`ed back off the phone. **Pull proven artifacts off the device before rebuilding anything.**
* Proven originals are archived in `backups/` (see §6).

### 5.9 Reading state when the bridge is dead

* After the module loads, the root bridge is gone and shell is blinded by KernelSU's path hiding:
  `/data/adb` → `Permission denied`, `dmesg` → `Permission denied` for shell. **Use `su -c '…'` instead** —
  that is the whole point of having root: `su -c 'dmesg | tail'`, `su -c 'ls /data/adb'`.
* Before the module loads, use the helper: `helper -c '…'`.
* Per-attempt evidence lives in `/data/local/tmp/solid/b<boot>a<attempt>/gate.txt`. `exploit completed` =
  kernel win; `refusing retry on this boot` = that process cannot retry; `pipe page child did not report base`
  / `F_SETPIPE_SZ … Operation not permitted` = budget pressure, not corruption.

---

## 6. Artifacts inventory

### 6.1 On the phone (all persistent in `/data`)

| Path | What | md5 |
| --- | --- | --- |
| `/data/adb/ksud` | `KSUD_PATH` — KernelSU userspace, required for `su` | `939a2f454946baf9de4409d16c5a2180` (read it as root: `su -c md5sum …`) |
| `/data/adb/ksu/bin/ksud` | same binary, normal install location | `939a2f454946baf9de4409d16c5a2180` |
| `/data/local/tmp/cve-2026-43499-root2` | **helper in use** (proven + socket-renamed) | `c9dd4c0cd7cfad24d2bcfa07d40621a7` |
| `/data/local/tmp/cve-e1q-102-stable.so` | **preload in use** (proven + socket-renamed) | `0d241f8374a99edcbc88eb783b37e5f6` |
| `/data/local/tmp/cve-2026-43499-root` | original helper (unmodified, channel now clean too) | `5736b811531362aac8a4a4f3fd8b0705` |
| `/data/local/tmp/cve-e1q-101-stable.so` | original preload (same) | `b5dac617d77d5da1afa0827dd487da31` |
| `/data/local/tmp/ksud-candB` | the working loader | `939a2f454946baf9de4409d16c5a2180` |
| `/data/adb/ksumodules` etc. | KernelSU module dirs created by the load | — |

### 6.2 On blackie

| Path | What |
| --- | --- |
| `backups/cve-2026-43499-root.proven` | the proven helper, unmodified (md5 `5736b811…`) |
| `backups/cve-e1q-101-stable.proven.so` | the proven preload, unmodified (md5 `b5dac617…`, recovered from the phone) |
| `backups/cve-2026-43499-root.sutemp` | **the shipped** socket-renamed helper (md5 `c9dd4c0c…`) |
| `backups/cve-e1q-101-stable.sutemp.so` | **the shipped** socket-renamed preload (md5 `0d241f83…`) |
| `solid_root.sh` | the procedure (v3 + lock + env overrides + cleanup) |
| `phone_autoroot.sh` | the watcher loop source |
| `phone-autoroot.service` | unit source (installed to `/etc/systemd/system/`) |
| `/usr/local/sbin/phone-autoroot.sh` | installed watcher (md5 `915d32def9f468486d5866a11167e03f`) |
| `/etc/systemd/system/phone-autoroot.service` | installed unit (md5 `e397ccb8c24cf367d144ed1279ee239c`) |
| `logs/host/solid_root_*.log`, `logs/phone-autoroot.log` | all run logs; the autoroot log is the one to read first |
| `logs/host/lastkmsg_*.log`, `logs/host/pstore_*` | crash forensics from the RKP reset |
| `kernelsu/` | the loader/module collection, patches, `tools/audit_module_against_target.py` |
| `/srv/storage/work/e1q-kernelsu/` | the kernel build tree + **our own native e1q `kernelsu.ko`** (audited clean, 202 undefined / 0 missing / 0 CRC mismatches — **never hardware-tested**, kept as a spare) |
| `/srv/storage/work/s24-root/` | firmware downloads, `vmlinux_s921w_dzh3.elf` (audit reference) |

---

## 7. The automation (what keeps it rooted)

`/etc/systemd/system/phone-autoroot.service` (**enabled**, **active**):

```ini
[Unit]
Description=Re-root the USB-attached Galaxy S24 (e1q / SM-S921W) after every reboot
RequiresMountsFor=/srv/storage

[Service]
Type=simple
User=blackieserver                     # same user as the adb server — never root
Environment=SOLID_HELPER=/data/local/tmp/cve-2026-43499-root2
Environment=SOLID_PRELOAD=/data/local/tmp/cve-e1q-102-stable.so
ExecStart=/usr/local/sbin/phone-autoroot.sh
Restart=always
RestartSec=15
Nice=5

[Install]
WantedBy=multi-user.target
```

Watcher logic (`phone_autoroot.sh`): every 20 s — if a device is present and `su -c id` is not `uid=0` and no
`solid_root.sh` is already running, log and run `solid_root.sh 8`; on failure sleep 300 s (anti-hammer);
log everything to `logs/phone-autoroot.log`.

Operate it:

```bash
systemctl status phone-autoroot.service --no-pager
sudo systemctl stop  phone-autoroot.service     # pause (e.g. phone off for the day)
sudo systemctl start phone-autoroot.service     # resume
tail -f /srv/storage/work/s24-root-payloads-2026-09-30/logs/phone-autoroot.log
```

**Pause it before unplugging the phone for long**, otherwise a failed run can retry forever (8 boots/run, 5 min
cooldown). It cannot damage the phone, but it will reboot it repeatedly while trying.

---

## 8. Verification evidence (this session, for the record)

```
# 1. First successful module load (candidate B), no reboot, phone alive:
kernelsu 212992 0 - Live 0x0000000000000000 (O)

# 2. First working su (shadow-bind route), SELinux Enforcing:
uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
KernelSU: newfstatat su->ksud!   KernelSU: faccessat su->ksud!   KernelSU: sys_execve su found
KernelSU: Samsung KDP task-scoped credential install pid=25175 uid=0 euid=0

# 3. Procedure run on the fixed channel (unattended by solid_root.sh):
08:56:20 boot 1 → 3 dead attempts → reboot
09:05:52 boot 2 → 09:09:42 attempt 7: ROOT LIVE
09:09:46 bind_rc=0 ( /system/bin/logcat = ksud )
09:09:55 module kernelsu Live ; su -c id = uid=0 … u:r:ksu:s0 ; Enforcing ; poisoned node deleted

# 4. REBOOT TEST — nothing but an adb reboot, then hands off:
09:10:23 adb reboot issued
09:10:50 watcher: "phone present WITHOUT root -> re-establishing"   (27 s after boot)
09:22:22 su -c id = uid=0 … u:r:ksu:s0          ← ROOT BACK, UNATTENDED (12 min total)
09:22:23 watcher: "re-root OK"
# and still rooted ~29 min later (uptime 1750, module Live, Enforcing) with no further intervention
```

---

## 9. Troubleshooting playbook

| Symptom | Most likely cause | Action |
| --- | --- | --- |
| `su: inaccessible or not found` while `kernelsu` **is** in `/proc/modules` | module loaded **without** `--allow-shell` | module param is load-time-only; wait for the next boot, or reboot now and let the procedure load it properly |
| `su: connect daemon: Permission denied` (EACCES) | **poisoned/stale socket** | use the renamed-channel pair (`root2` + `102-stable.so`); the shipped procedure already does; and `su -c 'rm -f …temp_su.sock'` once you have root |
| `su: connect daemon: No such file or directory` (ENOENT) | clean channel, no daemon yet (normal pre-root) | keep grinding |
| Loader exec returns `Killed`, dmesg shows `[DEFEX] Safeplace violation` | exec path is not a system path | bind-mount over a system binary first (`/system/bin/logcat`), then exec that path |
| Phone reboots the moment the module loads | wrong embedded module (sys_call_table patch + RKP) | you loaded candidate **A**. Use `ksud-e3q-S9280ZCS6DZF2-kdp` only. Read `/proc/last_kmsg` to confirm |
| `F_SETPIPE_SZ … Operation not permitted` in the gate file | uid-2000 pipe budget (by design) | wait ~90 s, retry; do **not** reboot for this alone; never run two attempts at once |
| Many attempts, always `cfi misc_fops mismatch ret=0` | the normal lottery loss | more attempts; consider a reboot after 3 consecutive dead attempts |
| Attempts say `refusing retry on this boot` | that process can't retry (stack writer already ran) | next process/attempt, or reboot |
| `/data/adb` or `dmesg` → `Permission denied` for **shell** | KernelSU path hiding (module is loaded) | use `su -c '…'` |
| adb shows no device | USB re-enumeration on reboot (not a boot loop) | `adb kill-server; adb start-server` — the watcher does this itself |
| Watcher flapping / rebooting the phone repeatedly | phone unplugged or genuinely unrootable at the moment | `sudo systemctl stop phone-autoroot.service` |
| Want the "why did it reset" answer | pstore is empty on this device | read `/proc/last_kmsg` (as root) — it holds the previous boot's kernel log |

---

## 10. Limits, risks, and open items

* **USB tether is a hard dependency.** Phone off the cable ⇒ no re-root. Wireless adb is *possible* over the
  tailnet, but the phone's wireless-debugging toggle does not reliably survive reboots, so USB is the supported
  path. If wireless is ever wanted, it must be re-tested end-to-end after a reboot before trusting it.
* **There is no on-device re-root.** Root My Galaxy's support feed (`support/targets-v3.json`) contains **zero**
  e1q/S921W entries, and the app itself is not in this repo ("intentionally does not contain Android application
  source code"). The `build/e1q-S921WVLS6DZH3/` artifacts are *ours*, not upstream.
* **Expect minutes, not seconds**, per re-root: attempts are ~35–60 s each, success ~1 in 2–10, plus reboots.
  Observed 12 minutes end-to-end. A worst case of 20+ minutes is normal, not a fault.
* **Every reboot of the phone = a window with no root** until the watcher finishes. Do not rely on root being
  up 100 % of the time.
* **The exploit is a memory-corruption kernel bug.** Repeated use has not damaged anything in these runs
  (successes and failures alike leave no persistent damage per the payload docs), but it is a kernel exploit on
  your daily phone: keep the phone backed up, and pause the watcher if you don't need root.
* **Not hardware-tested:** our own native `e1q` `kernelsu.ko` (audited clean, kept as a spare in
  `/srv/storage/work/e1q-kernelsu/kernelsu-built/`), and the e1q *app-domain* payload
  (`build/e1q-S921WVLS6DZH3/cve-2026-43499-app*.so`, `--run-payload`) — the app-domain route would be the way
  to a Shizuku/service-based on-device re-root if USB ever becomes unacceptable.
* **Source/binary divergence (cosmetic):** the tree's three socket constants were edited to `temp_su2.sock`
  while the shipped binaries carry `su_temp.sock` (the byte-patch name). If you ever rebuild, reconcile them —
  and keep the same length (28 bytes) if you intend to byte-patch again instead of rebuilding.
* **`/tmp/android-ndk-r27c` is on a tmpfs** — gone after a blackie reboot; re-download before any rebuild.

---

## 11. Cleanup / rollback

```bash
# Stop the automation
sudo systemctl disable --now phone-autoroot.service

# Remove it entirely
sudo rm -f /etc/systemd/system/phone-autoroot.service /usr/local/sbin/phone-autoroot.sh
sudo systemctl daemon-reload

# Phone-side: stop re-loading KernelSU (it is volatile anyway — a reboot clears the module)
#   remove the persistent userspace if you want it gone as well:
adb shell "su -c 'rm -rf /data/adb/ksud /data/adb/ksu'"
# Stage files can go too (they are the whole payload):
adb shell "rm -rf /data/local/tmp/cve-* /data/local/tmp/ksud-candB /data/local/tmp/solid /data/local/tmp/temp_su*.sock /data/local/tmp/su_temp.sock"
```
Nothing here modified any partition or the boot chain, so there is nothing else to undo: a reboot leaves the
phone exactly as Samsung shipped it (minus files in `/data`).

---

## 12. One-paragraph version for the next session

> e1q/SM-S921W on `S921WVLS6DZH3`, locked bootloader, KernelSU is a **late-loaded LKM** and therefore per-boot.
> Working chain: exploit root (uid-2000 pipe lottery, ~1 in 10 attempts) → `/data/adb/ksud` (persistent, =
> `KSUD_PATH`) → bind-mount that binary over `/system/bin/logcat` (DEFEX only allows exec from a system path;
> no overlayfs on this kernel) → `late-load --allow-shell --ephemeral --kmi android14-6.1` using **only**
> `ksud-e3q-S9280ZCS6DZF2-kdp` (the S928U loader patches `sys_call_table` and RKP resets the phone) → module
> init kills the exploit's root bridge (do root-only prep BEFORE the load) → `su -c id` gives `uid=0`,
> `u:r:ksu:s0`, Enforcing. Never let a socket inode in `/data/local/tmp` go stale: it is the exploit's root
> channel and a poisoned one (EACCES on stat/connect/unlink) makes real kernel wins invisible; the shipped pair
> uses a renamed channel and the procedure deletes the sockets with real root on success. Automation:
> `phone-autoroot.service` (systemd, enabled) + `phone-autoroot.sh` watcher + `solid_root.sh` procedure, all in
> `/srv/storage/work/s24-root-payloads-2026-09-30/`. Verified: reboot → rooted again in 12 minutes, unattended.

---

## 13. Flashing / TRUE PERSISTENCE — feasibility, verified lock state, and the exact next step

*(Added 2026-10-02 for the follow-up session that wants to try firmware modification + flashing. Read this
before spending any time on it: one property decides the whole plan, and it is a one-command check.)*

### 13.1 The dependency chain (there is no shortcut)

```
persistent root  ←  modified boot image running every boot
                 ←  flashing a modified image
                 ←  an UNLOCKED bootloader (AVB will not boot unsigned/modified images)
                 ←  the "OEM unlocking" toggle in Developer Options
```
Every link had to hold. It is not possible to patch a partition and keep a locked bootloader — dm-verity and
AVB are enforcing on this device (props below), so a modified image is rejected, not just warned about.

### 13.2 Verified lock state (measured on the device, 2026-10-02, not assumed)

```
ro.boot.flash.locked          = 1
ro.boot.vbmeta.device_state   = locked          ← definitive AVB state
ro.boot.verifiedbootstate     = green
ro.boot.veritymode            = enforcing
ro.boot.veritymode.managed    = yes              ← Samsung managed verity
ro.config.dmverity            = G
ro.boot.vbmeta.avb_version    = 1.2
ro.boot.vbmeta.size           = 14848
ro.boot.warranty_bit          = 0                ← KNOX NOT TRIPPED (still a one-way door)
ro.secure                     = 1
ro.adb.secure                 = 1
ro.oem_unlock_supported       = (NOT SET)
sys.oem_unlock_allowed        = (NOT SET)
```

* `ro.oem_unlock_supported` being **absent** is a hint (Samsung does not always define this AOSP prop) that the
  OEM-unlocking toggle is not exposed on this variant — but it is **not** proof. `ro.boot.vbmeta.device_state=locked`
  and `ro.boot.flash.locked=1` **are** proof of the current state.
* `ro.boot.warranty_bit = 0` means the Knox fuse has **not** been blown yet. Flashing a modified image (or even
  just unlocking the bootloader on most Samsung models) sets it to 1 **permanently and irreversibly**, killing
  Samsung Wallet/Pass, Secure Folder, and some banking/DRM apps, and adding a boot warning screen. Worth
  knowing the price before opening that door.

### 13.3 The one test that decides everything (10 seconds, on the phone)

**Settings → About phone → Software information → tap "Build number" ×7 → Developer options → look for
"OEM unlocking".**

| You see | Meaning |
| --- | --- |
| No such toggle at all | Bootloader cannot be unlocked on this variant → **flashing route is dead**; the watcher (§7) is the endgame |
| Toggle present but greyed out | Samsung's usual "prenormal / RMM" or carrier lock state → do not fight it; treat as unavailable |
| Toggle present and usable | Unlocking is possible — read §13.4 before flipping it (it wipes the phone) |

If it becomes usable and is enabled, `sys.oem_unlock_allowed` should read `1` and the unlock itself is done from
Download/Odin mode (long-press Vol-Up on the unlock screen), **not** from adb. Expect a **full factory reset**
as part of unlocking.

If the bootloader stays locked, do not waste a session on Odin experiments: a locked bootloader rejects any
non-official image (`Only official released binaries are allowed`, `SECURE CHECK FAIL`, or a prenormal/RMM
refusal). Nothing in the current root work touches a partition, which is exactly why it works.

### 13.4 If (and only if) unlocking is available — the persistent route

1. **Unlock** (accept: full wipe + Knox bit 0 → 1, permanently).
2. Take the **exact** firmware for this device — already on disk (§13.5) — and extract `boot.img`
   (already extracted) / `init_boot.img` if the AP contains one.
3. **Patch the boot image with KernelSU** (or Magisk) for this kernel version: GKI SM8650 / `6.1.145-android14`
   → use KernelSU's `boot_patch.sh` / the KernelSU app's "patch a file" flow on the matching version, or the
   Magisk route in `references/alternative-root-methods.md` (skill: `android-root-exploit`).
4. Handle AVB/verity: patch `vbmeta` with `--disable-verity --disable-verification` (or use a boot patch that
   keeps verification satisfiable — KernelSU's patch for GKI handles this by design; verify against KernelSU's
   docs for the exact version rather than assuming).
5. Flash with Odin using the **same build** (BL unchanged, AP with the patched `boot.img`), keep the phone
   data-less or use HOME_CSC deliberately — and **never downgrade the BL**.
6. Result: KernelSU loads from the boot image every boot → `su` works natively, KernelSU **modules** become
   available, and the whole late-load chain in this document becomes unnecessary. The exploit, the loader
   candidate hunt, `--allow-shell`, the DEFEX shadow-bind and the watcher all retire.

Note: with a proper flashed KernelSU install, the late-load constraints vanish (no `allow_shell` gate, no
`--ephemeral`, no per-boot re-establishment) — that is the real prize, and it is the only thing that makes the
word "persistent" honest for this device.

### 13.5 Material already on hand (no downloads needed)

| Path | What |
| --- | --- |
| `firmware/downloads/BL_S921WVLS6DZH3_…_MULTI_CERT.tar.md5` | BL — 98 MB |
| `firmware/downloads/AP_S921WVLS6DZH3_…_meta_OS16.tar.md5` | AP (kernel/system) — 15.07 GB |
| `firmware/downloads/CP_S921WVLS6DZH3_CP35862464_…tar.md5` | CP (modem) — 82 MB |
| `firmware/downloads/CSC_OYV_S921WOYV6DZH3_…tar.md5` | CSC — 517 MB |
| `firmware/downloads/HOME_CSC_OYV_S921WOYV6DZH3_…tar.md5` | HOME_CSC (no-wipe variant) — 517 MB |
| `firmware/downloads/extracted/boot.img` | **boot.img already extracted** (100 MB) — the file a KernelSU/Magisk patch would modify |
| `firmware/downloads/extracted/vmlinux_s921w_dzh3.elf`, `kernel_image.arm64`, `nm_s921w.txt` | kernel + symbols, already extracted (used for the offset audits) |
| free space | `/srv/storage` 2.9 TB free — no constraint |

All of it is in `/srv/storage/work/s24-root/` (see `firmware/fw_download.sh`, `firmware/firmware_list.json` for
provenance). Nothing here is a guess: these are the tars for the exact `S921WVLS6DZH3` build the phone runs.

### 13.6 Honest bottom line

* If the OEM-unlocking toggle is **absent** on this SM-S921W: persistent root is not achievable by any amount of
  firmware work, full stop. The watcher is not a consolation prize — it is the answer, and it is already built,
  installed, and verified.
* If it is **present and usable**: true persistence is genuinely reachable, at the cost of a wipe and the Knox
  fuse. Then flashing a KernelSU-patched boot image makes root permanent and retires this entire document's
  late-load machinery.
