#!/usr/bin/env python3
"""Run install.sh under a pty in the stub test env and capture full output.

Usage: pty-menu.py <mode> <outfile>
  mode: menu    -> no ACTION, feed Enter (default 2 = view) then 6 (exit)
        menu-loop -> no ACTION, feed 2 (view, no node) then 6 (exit)
        preset-return -> no ACTION, needs a node: feed 5 (preset) then 0 (return) then 6 (exit)
        preset  -> ACTION=preset, feed Enter (return 0)
        delete  -> ACTION=delete, feed Enter (default N = cancel, keeps node)
        preset-create -> ACTION=preset, feed 1 (GCP) then Enter (port default 443)
        edit-preset -> ACTION=edit, feed 8443 (new port) then Enter (keep SNI)
"""
import os
import pty
import sys
import time

T = "/tmp/vx-traffic-test"
ENV = dict(os.environ)
ENV.update({
    "TQ_TEST_ROOT": f"{T}/run",
    "TQ_SYSFS_ROOT": f"{T}/run/sysfs",
    "TQ_IFACE": "eth0",
    "PATH": f"{T}/bin:" + ENV.get("PATH", ""),
    "HOME": f"{T}/home",
    "LC_ALL": "C",
    "TZ": "UTC",
    "VX_BIN": f"{T}/vxbin/vx",
    "VX_BACKUP": f"{T}/vxbin/vx-install.sh",
})

# fresh stub run dir (like setup_run, but keep the installed node)
os.system(f"rm -rf {T}/run {T}/home/.acme.sh")
os.makedirs(f"{T}/run/sysfs/eth0/statistics", exist_ok=True)
os.makedirs(f"{T}/home", exist_ok=True)
os.makedirs(f"{T}/vxbin", exist_ok=True)
for name, val in [("xray.active", "1"), ("tc.root", "0"), ("tc.ingress", "0")]:
    open(f"{T}/run/{name}", "w").write(val)
for name in ["log", "ipt.rules", "ipt.counters"]:
    open(f"{T}/run/{name}", "w").write("")
open(f"{T}/run/sysfs/eth0/statistics/rx_bytes", "w").write("0")
open(f"{T}/run/sysfs/eth0/statistics/tx_bytes", "w").write("0")

mode = sys.argv[1]
outfile = sys.argv[2]
if mode == "preset":
    ENV["ACTION"] = "preset"
if mode == "delete":
    ENV["ACTION"] = "delete"
if mode == "preset-create":
    ENV["ACTION"] = "preset"
if mode == "edit-preset":
    ENV["ACTION"] = "edit"

FEEDS = {
    "menu": [b"\n", b"6\n"],
    "menu-loop": [b"2\n", b"6\n"],
    "preset-return": [b"5\n", b"0\n", b"6\n"],
    "preset": [b"\n"],
    "delete": [b"\n"],
    "preset-create": [b"1\n", b"\n"],
    "edit-preset": [b"8443\n", b"\n"],
}

pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/bash", ["bash", "/home/hatch/workspace/vx/install.sh"], ENV)
else:
    time.sleep(1.0)
    for chunk in FEEDS.get(mode, [b"\n"]):
        try:
            os.write(fd, chunk)
        except OSError:
            break
        time.sleep(0.7)
    out = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    _, status = os.waitpid(pid, 0)
    text = out.decode("utf-8", "replace").replace("\r\n", "\n")
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {outfile} rc={os.waitstatus_to_exitcode(status)} bytes={len(text)}")
