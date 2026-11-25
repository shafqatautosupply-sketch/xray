Xray - process + kernel inspector for jailbroken iOS 6 (iPhone 4S, armv7)

ARCHITECTURE (changed: the app is no longer setuid)
  Xray.app     normal app, runs as mobile, chmod 755. All UI.
  xrayd        small command-line helper, setuid root, /usr/libexec/xrayd. Does task_for_pid,
               thread/stack sampling, memory reads and kdebug. The app runs it (like Cydia's cydo)
               and reads the result back through a pipe.
  SpringBoard silently kills a setuid app, so only the helper carries the setuid bit.

BUILD
  cd Xray && make package install
  The Makefile builds both Xray and xrayd. postinst sets: chmod 4755 /usr/libexec/xrayd

IF make package FAILS: build and install by hand
  make                       (find outputs with:  find . -name xrayd -type f ; find . -name Xray.app)
  cp <path>/xrayd /usr/libexec/xrayd
  chown root:wheel /usr/libexec/xrayd && chmod 4755 /usr/libexec/xrayd
  chmod 755 /Applications/Xray.app/Xray      <- must NOT be setuid
  ldid -Sentitlements.plist /usr/libexec/xrayd     (sign BEFORE the chmod, signing can reset the bit)
  uicache
  Re-run the chown/chmod lines after any reinstall.

CHECK THE HELPER (over SSH)
  /usr/libexec/xrayd access     prints binary data if it runs; no output / "not found" = not installed
  ls -l /usr/libexec/xrayd      should be  -rwsr-xr-x root wheel
  Overview tab > Access shows "Helper: running as uid 0 / euid 0" when it works.

trace.codes
  Copy your trace.codes to the device as  /usr/share/misc/trace.codes  (also tried:
  /usr/libexec/trace.codes, /Applications/Xray.app/trace.codes, /var/mobile/trace.codes).
  It is read by the helper. It gives real event names and the real VFS_LOOKUP id used to rebuild
  file paths. Without it the built-in syscall table is used.

SCREENS (top-right button flips Easy / Pro everywhere)
  Overview   chrome CPU + memory gauges, busiest apps, VM/CPU details (Pro)
  Processes  LED-meter list, sortable; tap for detail
    Detail   summary, counters, threads+stacks, 5 s sampler, memory map, open files,
             live kernel trace for that pid, hex viewer, signals (Pro)
  Trace      live kdebug events: syscalls with file paths (Easy) or raw events (Pro)
  Kernel     version/limits, per-core load, full sysctl browser, kernel threads,
             read-only kernel memory hex (Pro)

SECURITY NOTE
  xrayd is setuid root and executable by any local user/app. It is read-only (process info, memory
  reads, kdebug) apart from sending STOP/CONT/TERM/KILL to pids > 1. Fine for a personal test phone;
  remove /usr/libexec/xrayd when you are done if you care.

NOTES
  * Written without a compiler for the 6.1 SDK; expect a few small compile fixes.
  * kdebug struct layouts assume xnu ~2107 (iOS 6) armv7. Adjust XKd/XKdThr in XTrace.m if needed.
  * Memory access is read-only. Thread suspends last microseconds and are always resumed;
    kernel_task threads and the helper's own threads are never suspended.
  * Tracing is switched off when the app goes to the background.
