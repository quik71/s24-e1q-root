#!/bin/bash
# phone_autoroot.sh — keep the USB-attached Galaxy S24 (e1q / SM-S921W) rooted across reboots.
#
# WHY THIS EXISTS: root on this phone is structurally volatile. The exploit is an in-RAM kernel bug and
# KernelSU is a late-loaded LKM; a reboot erases both. Real persistence (KernelSU baked into the boot
# image) is impossible here — the bootloader is locked and ro.boot.verifiedbootstate=green, so nothing can
# be flashed. Root My Galaxy's app feed does not even list e1q/S921W, so there is no supported on-device
# re-root either. What CAN be automatic is re-establishment: this watcher notices the phone came back
# without root and runs the proven procedure, unattended, within seconds.
#
# Runs as the user that owns the adb server (blackieserver) as a systemd --user unit with linger, so it
# starts at boot with no login and never fights a second adb server for USB.
#
# Guards: never overlap a run (a concurrent attempt starves the uid-2000 pipe budget), and back off hard
# after a failed run instead of hammering the phone.
# WORK = your clone of this repo. EDIT THIS LINE (or export PHONE_ROOT_WORK before starting the unit).
# It cannot be derived from this script's own location, because the unit installs the script into
# /usr/local/sbin, far away from the clone it drives.
WORK=${PHONE_ROOT_WORK:-$HOME/s24-e1q-root}
LOG=$WORK/logs/phone-autoroot.log

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log(){ echo "$(date -Is) $*" >> "$LOG"; }
log "watcher started (pid $$)"

while true; do
  if [ ! -d "$WORK" ]; then
    log "work dir $WORK not mounted yet; waiting"
    sleep 60
    continue
  fi

  if adb devices 2>/dev/null | grep -q "device$"; then
    if ! adb shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q "uid=0"; then
      if pgrep -f "solid_root[.]sh" >/dev/null 2>&1; then
        log "a solid_root run is already in flight; not starting another"
      else
        log "phone present WITHOUT root -> re-establishing"
        if timeout 2400 bash "$WORK/scripts/solid_root.sh" 8 >> "$LOG" 2>&1; then
          log "re-root OK: $(adb shell 'su -c id' 2>/dev/null | tr -d '\r')"
        else
          rc=$?
          log "re-root FAILED (rc=$rc); cooling down 300s"
          sleep 300
        fi
      fi
    fi
  fi
  sleep 20
done
