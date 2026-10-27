# Root a Galaxy S24 with a locked bootloader — the simple install

This is the short version. It works on **one** phone and **one** software version. Check that you have
both before you start, or you will waste an afternoon.

What you get: root (`su`), via KernelSU, on a phone whose bootloader stays **locked**. Nothing is
flashed, nothing is wiped, Knox stays intact. Because nothing is flashed, root disappears when you
reboot — and the last step makes it come back by itself.

---

## Step 0 — Check your phone matches. Do not skip this.

Plug the phone into a computer with USB debugging on, then run:

```bash
adb shell getprop ro.product.model      # want: SM-S921W
adb shell getprop ro.build.fingerprint  # want: the part that says S921WVLS6DZH3
adb shell uname -r                      # want: 6.1.145-android14-11-33419968
adb shell getprop ro.boot.flash.locked  # want: 1  (locked is fine, that's the point)
```

**If the version string is not exactly `S921WVLS6DZH3`, stop.** Same phone model with a different
software update does not work — the numbers inside the kernel have moved and the exploit will not
land. This mismatch is the most common way this approach fails — it is the wall we hit ourselves first.

You also need: a **Linux** PC (or WSL) with `adb` installed, and a decent USB cable.

---

## Step 1 — Get the files

```bash
git clone https://github.com/quik71/s24-e1q-root.git
cd s24-e1q-root
```

---

## Step 2 — Put three files on the phone

They must go to `/data/local/tmp`. **Not** `/sdcard` — that folder is invisible to the program that
loads them, and you'll get a confusing "cannot link executable" error.

```bash
adb push backups/cve-e1q-101-stable.sutemp.so /data/local/tmp/cve-e1q-102-stable.so
adb push backups/cve-2026-43499-root.sutemp   /data/local/tmp/cve-2026-43499-root2
adb push kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp  /data/local/tmp/ksud-candB
adb shell chmod 755 /data/local/tmp/cve-e1q-102-stable.so /data/local/tmp/cve-2026-43499-root2 /data/local/tmp/ksud-candB
```

The names matter — the script looks for exactly those. Use only that one `ksud-...` file in `kernelsu/`;
the other loaders we tried make the phone instantly reboot (a Samsung security feature called RKP
objects to what they do).

Check the copies are complete — these md5s should match:

```bash
md5sum backups/cve-e1q-101-stable.sutemp.so   # 0d241f8374a99edcbc88eb783b37e5f6
md5sum backups/cve-2026-43499-root.sutemp     # c9dd4c0cd7cfad24d2bcfa07d40621a7
md5sum kernelsu/ksud-e3q-S9280ZCS6DZF2-kdp    # 939a2f454946baf9de4409d16c5a2180
```

---

## Step 3 — Run it

```bash
SOLID_PRELOAD=/data/local/tmp/cve-e1q-102-stable.so \
SOLID_HELPER=/data/local/tmp/cve-2026-43499-root2 \
bash scripts/solid_root.sh 8
```

This takes roughly 10–15 minutes and **reboots the phone on its own**, more than once. That is
normal, not a fault. Leave the USB cable alone and let the screen stay on.

Why it reboots: getting root this way is a race with the kernel's memory allocator. Each attempt wins
about 1 time in 2 to 10, and after a few dead tries a fresh boot gives it better odds. It is not
broken, it is a lottery — you are pulling the lever until it hits.

Two rules while it runs:
- **One run at a time.** Two attempts at once share one 64 MB kernel limit and both fail.
- Don't unplug the phone. A disconnect resets progress.

---

## Step 4 — Prove it worked

```bash
adb shell "su -c 'id; getenforce'"
```

Good answer:

```
uid=0(root) gid=0(root) groups=0(root),... context=u:r:ksu:s0
Enforcing
```

If you get `su: connect daemon: Permission denied`, delete the stale socket and reboot once:

```bash
adb shell "rm -f /data/local/tmp/temp_su.sock /data/local/tmp/su_temp.sock"
adb reboot
```

That leftover socket is a nasty one: it survives the reboot, silently blocks the
root channel, and makes a working phone look broken.

---

## Step 5 — Make it survive reboots (optional, but this is the point)

Root here lives in RAM, so every reboot erases it. The watcher notices and fixes it within a couple of
minutes, with the phone sitting plugged in.

Two edits first, because the unit ships with placeholders:
in `scripts/phone_autoroot.sh` set `WORK=` to the folder you cloned into, and in
`scripts/phone-autoroot.service` change `User=CHANGE_ME` to **your** Linux username (the unit will
refuse to start until you do — that's deliberate, not a bug).

```bash
sudo cp scripts/phone_autoroot.sh /usr/local/sbin/phone-autoroot.sh   # the service expects it here
sudo cp scripts/phone-autoroot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now phone-autoroot
journalctl -f -u phone-autoroot
```

Unplug the phone for the day? Stop it first, or it will retry the whole grind against an absent phone:

```bash
sudo systemctl stop phone-autoroot
```

---

## If it goes wrong

| What you see | What it actually means |
|---|---|
| `cfi misc_fops mismatch` in the output | Wrong software version. Go back to Step 0. |
| `F_SETPIPE_SZ: Operation not permitted` | Two runs at once. Kill them, run one. |
| Module loads, but `su -c id` refuses | The module loaded without the `--allow-shell` switch. It cannot be fixed after loading — reboot and run again. |
| Phone reboots the instant it loads | Wrong loader file. Only `ksud-e3q-S9280ZCS6DZF2-kdp` is safe. |
| `cannot link executable … not accessible` | Files are in `/sdcard`. They must be in `/data/local/tmp`. |
| Nothing works, all attempts fail | Check the phone isn't asleep: Settings → Developer options → Stay awake while charging. |

---

## Two things to know before you try this

- This is a **kernel bug being forced**. We ran it repeatedly on our own phone with nothing
  breaking, but it is still an exploit, not an official root method. Back the phone up first.
- Do it on a phone you own.

Persistent root (stays after a reboot with no watcher) is possible only by unlocking the bootloader and
flashing a patched boot image. That costs a full factory reset and blows the Knox fuse permanently,
which kills Samsung Wallet, Secure Folder and some banking apps. We chose not to.
