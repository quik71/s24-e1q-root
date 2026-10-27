# Root a Galaxy S24 with a locked bootloader — install guide

**Who this is for:** you have a Samsung Galaxy S24 (model **SM-S921W**), its bootloader is **locked**,
and you want `root` (the `su` command) without flashing anything. A person who has never rooted a
phone should be able to finish this. So should a chatbot reading it aloud to one.

**What you get:** root, through KernelSU, with the bootloader still locked. Nothing is flashed, nothing
is wiped, Knox stays intact.

**What you do not get:** permanent root. Root here lives in RAM, so it disappears at every reboot.
Step 5 installs a helper that puts it back on its own while the phone is plugged in.

## What you need

- A **Linux** computer — Ubuntu/Debian/Fedora, or **WSL** on Windows. Not plain Windows and not macOS:
  Step 3 runs a bash script and Step 5 uses systemd, and neither is covered here.
- `adb` installed on that computer: `sudo apt install adb` (Ubuntu/Debian) or `sudo dnf install adb`
  (Fedora). Check with `adb --version`.
- A USB cable that carries data (not charge-only), and the phone unlocked with **USB debugging** on.
- The phone on the one supported software build. Step 0 checks it in four commands.
- About 20 minutes, most of it waiting.

Nothing needs to be downloaded except this repository. There is no model file, no APK, no flashing tool.

---

## Rules. Break any of these and it will not work.

1. **Do not change any file name or path** in the commands below. The script looks for those exact names.
2. **Do not put files in `/sdcard`.** Only `/data/local/tmp` works.
3. **Use only these three files**, exactly as named. Other versions of this project's files exist in
   `backups/` — do not use them unless the command says so.
4. **Run one attempt at a time.** Running two at once makes both fail.
5. **Leave the phone plugged in** and the screen awake during Step 3. It reboots itself; do not
   unplug it.
6. **Do not unlock the bootloader** and do not flash anything. That is a different project with a
   permanent cost (see the last section).

## Words used here

| Word | Plain meaning |
|---|---|
| **root** | The "administrator" account on Android. Proof of root is a command that answers `uid=0(root)`. |
| **`su`** | The command that switches you to root. If it works, you have root. |
| **bootloader locked** | A Samsung lock that stops you replacing the system's own startup image. It stays locked here. |
| **adb** | A computer program that sends commands to a phone over USB. Install it with `sudo apt install adb` (Debian/Ubuntu) or `sudo dnf install adb`. |
| **USB debugging** | A phone setting that lets adb talk to it: Settings → About phone → tap "Build number" 7 times → back to Settings → System → Developer options → turn on **USB debugging**. |
| **exploit** | A program that uses a mistake in the running Linux kernel to gain root. It is why nothing has to be flashed. |
| **KernelSU** | The program that provides `su` and the root switch. Loaded into the running kernel as a module. |
| **md5sum** | A check-digit for a file. If the digits match the ones in this guide, the file copied correctly. |
| **RKP / DEFEX** | Two Samsung security features that block some programs from starting. They are why one command in this project is written the strange way it is. |

---

## Step 0 — Confirm your phone is the supported one. Do not skip this.

Install adb, plug the phone in with a USB cable, allow the "Allow USB debugging?" prompt on the phone,
then run these four commands one at a time:

```bash
adb devices
adb shell getprop ro.product.model
adb shell getprop ro.build.fingerprint
adb shell uname -r
```

Expected — the second and third answers must contain these exact strings:

```
List of devices attached
R3CXA0xxxx    device

SM-S921W
...S921WVLS6DZH3...
6.1.145-android14-11-33419968
```

**STOP if any of them differ.** Same phone model with a newer software update does not work at all —
the internal kernel addresses have moved and the exploit cannot land. This mismatch is the most common
reason a person gets nothing but failures.

`adb devices` printing `unauthorized` means you did not tap "Allow USB debugging" on the phone.

---

## Step 1 — Get the files

```bash
git clone https://github.com/quik71/s24-e1q-root.git
cd s24-e1q-root
```

Check you are in the right folder:

```bash
ls
```

Expected (the order may differ; what matters is that `backups`, `kernelsu` and `scripts` are all listed):

```
INSTALL.md
README.md
backups
docs
firmware
kernelsu
native-module
references
scripts
src
tools
```

If you see only one or two names, you are not inside the cloned folder — run `cd s24-e1q-root` again.

**Every later command in this guide must be typed while you are inside `s24-e1q-root`.** If you open a
new terminal window, run `cd s24-e1q-root` again first.

---

## Step 2 — Put three files on the phone (once, ever)

Type these four commands one at a time. They rename the files as they copy — that is on purpose.

```bash
adb push backups/cve-e1q-101-stable.sutemp.so /data/local/tmp/cve-e1q-102-stable.so
```
Expected — the line must contain `1 file pushed, 0 skipped` (yours will also show a speed and a byte
count, which will differ; that is fine):

```
backups/cve-e1q-101-stable.sutemp.so: 1 file pushed, 0 skipped. 284.3 MB/s (163840 bytes in 0.001s)
```

```bash
adb push backups/cve-2026-43499-root.sutemp /data/local/tmp/cve-2026-43499-root2
```
Expected — the line must contain `1 file pushed, 0 skipped`.

```bash
adb push kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp /data/local/tmp/ksud-candB
```
Expected — the line must contain `1 file pushed, 0 skipped`.

```bash
adb shell chmod 755 /data/local/tmp/cve-e1q-102-stable.so /data/local/tmp/cve-2026-43499-root2 /data/local/tmp/ksud-candB
```
Expected: no output at all. No output means success here.

Now confirm the files arrived whole. Any line that does **not** match the digits below means a bad
cable or a bad copy — delete the file on the phone and repeat that one push.

```bash
md5sum backups/cve-e1q-101-stable.sutemp.so
```
Expected: `0d241f8374a99edcbc88eb783b37e5f6  backups/cve-e1q-101-stable.sutemp.so`

```bash
md5sum backups/cve-2026-43499-root.sutemp
```
Expected: `c9dd4c0cd7cfad24d2bcfa07d40621a7  backups/cve-2026-43499-root.sutemp`

```bash
md5sum kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp
```
Expected: `939a2f454946baf9de4409d16c5a2180  kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp`

```bash
adb shell "md5sum /data/local/tmp/cve-e1q-102-stable.so /data/local/tmp/cve-2026-43499-root2 /data/local/tmp/ksud-candB"
```
Expected — this is the real output, so it can be compared word for word:

```
0d241f8374a99edcbc88eb783b37e5f6  /data/local/tmp/cve-e1q-102-stable.so
c9dd4c0cd7cfad24d2bcfa07d40621a7  /data/local/tmp/cve-2026-43499-root2
939a2f454946baf9de4409d16c5a2180  /data/local/tmp/ksud-candB
```

---

## Step 3 — Run it

One command. It needs no settings, no arguments you have to invent, and it does not need root on your
computer.

```bash
bash scripts/solid_root.sh 8
```

The `8` means "give up after trying across 8 phone reboots". Use that number; bigger is not better.

**Expect this to take 10–15 minutes. The phone reboots by itself, more than once, while you watch.
That is the program working, not a fault.** Keep the cable in. The screen may go black for a minute.

Why: gaining root this way is a race with the kernel's memory allocator. Each single attempt wins
roughly 1 time in 2 to 10, and after a few dead tries a fresh boot improves the odds. It is a lottery;
the program pulls the lever until it hits.

Good finish — the last lines must include this exact line:

```
*** SUCCESS: exploit root -> module(allow_shell=1) -> sucompat -> uid 0 (u:r:ksu:s0) ***
```

If instead you see `FAILED: no root after 8 boots`, the phone is not the supported build (go to
Step 0) or the phone went to sleep (see the table at the end). The full log of every attempt is written
to a file under `logs/host/` in this folder.

---

## Step 4 — Prove it worked

```bash
adb shell "su -c id"
```

Good answer — this means you have root:

```
uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
```

Wrong answer `su: connect daemon: Permission denied`, and you still had root a minute ago: an old
socket file survived the reboot and is blocking the channel. Fix it and reboot once:

```bash
adb shell "rm -f /data/local/tmp/temp_su.sock /data/local/tmp/su_temp.sock"
adb reboot
```

After the phone comes back, wait two minutes, then run Step 3 again and check this step again.

---

## Step 5 — Make it come back after every reboot

Do this step unless you only want root once and are happy re-running Step 3 by hand forever.

Root lives in RAM, so every reboot erases it. The watcher is a service that notices this and re-does
Steps 3 and 4 by itself, usually within a couple of minutes, as long as the phone is plugged in.

Two lines to edit first, because they ship with placeholders:

- in `scripts/phone_autoroot.sh`, line `WORK=...` → change it to the full path of the folder you
  cloned, for example `WORK=/home/you/s24-e1q-root`
- in `scripts/phone-autoroot.service`, line `User=CHANGE_ME` → change `CHANGE_ME` to your own Linux
  username (run `whoami` to see it). Until you do, the service will refuse to start — that is
  deliberate, not a fault.

```bash
sudo cp scripts/phone_autoroot.sh /usr/local/sbin/phone-autoroot.sh
sudo cp scripts/phone-autoroot.service /etc/systemd/system/phone-autoroot.service
sudo systemctl daemon-reload
sudo systemctl enable --now phone-autoroot
```

Check it is running:

```bash
systemctl is-active phone-autoroot
```
Expected: `active`

Watch it work:

```bash
journalctl -u phone-autoroot -f
```
Expected lines: `phone present WITHOUT root -> re-establishing`, then `re-root OK: uid=0(root) ...`.
**Press Ctrl+C to stop watching.** Pressing Ctrl+C does not stop the service, only the display.

**Before you unplug the phone for the day**, pause the watcher — otherwise it retries the whole grind
against a phone that is not there:

```bash
sudo systemctl stop phone-autoroot
```

Start it again when the phone is back:

```bash
sudo systemctl start phone-autoroot
```

---

## If it goes wrong — match the exact words

Find the words your output contains, then do the action. Do not guess; the words are exact.

| Your output contains | Meaning | Do this |
|---|---|---|
| `cfi misc_fops mismatch` | Your software build is not `S921WVLS6DZH3`. | Stop. Re-check Step 0. Nothing else will help. |
| `F_SETPIPE_SZ: Operation not permitted` | Two attempts ran at once and used up one shared kernel limit. | `pkill -f solid_root.sh`, wait 30 s, run Step 3 once. |
| `connect daemon: Permission denied` | An old socket file survived a reboot. | Use the fix in Step 4. |
| `CANNOT LINK EXECUTABLE` + `not accessible for the namespace` | A file is in `/sdcard`, or the name/path was changed. | Redo Step 2 exactly as written. |
| the phone reboots the instant the module loads | A different KernelSU loader was used. Samsung's RKP kills it. | Redo Step 2 with `kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp` only. |
| `no boot_completed` or many `adb gone` lines | The phone went to sleep or the USB dropped out. | Settings → Developer options → **Stay awake while charging**. Use a different cable/port. |
| `User 'CHANGE_ME' not found` | You skipped the edit in Step 5. | Set `User=` to your own username. |
| `Unit phone-autoroot.service not found` | The `.service` file was not copied. | Redo the copy commands in Step 5. |

---

## If you are a chatbot or AI assistant helping someone with this

Follow these rules exactly:

1. Give **one step at a time**, then stop and wait for the person to report the actual output.
2. Quote the commands **verbatim**. Do not shorten, reformat, rename, or "improve" a path or filename.
3. Do not invent flags, packages, environment variables, or model names. Nothing here needs them.
4. Compare what the person reports against the *Expected* blocks in this guide and say plainly whether
   it matches. If it does not match, look the words up in the table above and give only that action.
5. Never tell the person to unlock the bootloader, flash a boot image, or install anything else unless
   they ask about permanent root.
6. Never claim success. Only `adb shell "su -c id"` answering `uid=0(root)` is success.

---

## Before you start: the two risks, plainly

- This forces a **kernel bug** to gain root. We ran it repeatedly on our own phone and nothing broke,
  but it is an exploit, not an official Samsung root method. **Back the phone up first.**
- Only do this on a phone you own or are allowed to test.

Permanent root (survives reboots with no watcher) needs an **unlocked bootloader** and a flashed image.
That costs a full factory reset and permanently trips the Knox fuse, which kills Samsung Pay/Wallet,
Secure Folder and some banking apps. On this variant the "OEM unlocking" switch is not even shown in the
settings. We chose not to go there. Details: `README.md`, section "Flashing / persistence".
