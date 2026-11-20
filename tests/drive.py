#!/usr/bin/env python3
"""Drive a test build of the Bink player through its BINKHUD_CTL fifo and print the log.
Usage: drive.py <video.bk2> "<cmd>;<sleep secs>;<cmd>..."   (numbers = sleep)"""
import os, sys, subprocess, time, tempfile
APP = os.environ.get("APP", os.path.join(os.path.dirname(__file__), "..", "build", "Bink Player.app"))
mac = os.path.join(APP, "Contents", "MacOS")
video, script = sys.argv[1], sys.argv[2]
d = tempfile.mkdtemp(prefix="binkhud-")
fifo, log = os.path.join(d, "ctl"), os.path.join(d, "log")
os.mkfifo(fifo)
env = dict(os.environ, DYLD_INSERT_LIBRARIES=os.path.join(mac, "libBinkHUD.dylib"), BINKHUD_CTL=fifo, BINKHUD_LOG=log, BINKHUD_TEST="1")
env["BINKHUD_LOOP"] = os.environ.get("LOOP", "0")
args = [os.path.join(mac, "BinkMacArmPlayer"), "-m", "-l", video]
p = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(1.2)
w = open(fifo, "w", buffering=1)
t0 = time.time()
for step in script.split(";"):
    step = step.strip()
    if not step: continue
    try: time.sleep(float(step)); continue
    except ValueError: pass
    if p.poll() is not None: print(f"!! player exited (code {p.returncode}) before '{step}'"); break
    w.write(step + "\n")
time.sleep(0.3)
alive = p.poll() is None
if alive:
    try: w.write("quit\n"); w.flush()
    except BrokenPipeError: pass
    time.sleep(0.6)
    if p.poll() is None: p.kill()
print(open(log).read() if os.path.exists(log) else "(no log)")
print("exit code:", p.returncode, "| was alive at end:", alive)
out = p.stdout.read().decode(errors="replace").strip()
if out: print("stdout:", out[-1500:])
