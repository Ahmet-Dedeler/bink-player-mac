#!/usr/bin/env python3
"""Drive a test build of the Bink player through its BINKHUD_CTL fifo and print the log.
Usage: drive.py <video.bk2> "<cmd>;<sleep secs>;<cmd>..."   (numbers = sleep)"""
import errno, os, shutil, subprocess, sys, tempfile, time

APP = os.environ.get("APP", os.path.join(os.path.dirname(__file__), "..", "build", "Bink Player.app"))
mac = os.path.abspath(os.path.join(APP, "Contents", "MacOS"))
if len(sys.argv) < 3:
    sys.exit(f'usage: {sys.argv[0]} <video.bk2> "<cmd>;<sleep>;..."')
video, script = sys.argv[1], sys.argv[2]
d = tempfile.mkdtemp(prefix="binkhud-")
fifo, log = os.path.join(d, "ctl"), os.path.join(d, "log")
os.mkfifo(fifo)
env = dict(
    os.environ,
    DYLD_INSERT_LIBRARIES=os.path.abspath(os.path.join(mac, "libBinkHUD.dylib")),
    BINKHUD_CTL=fifo,
    BINKHUD_LOG=log,
    BINKHUD_TEST="1",
)
env["BINKHUD_LOOP"] = os.environ.get("LOOP", "0")
args = [os.path.join(mac, "BinkMacArmPlayer"), "-m", "-l", video]
t_start = time.time()
p = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
w = None
alive = False
try:
    # Poll non-blocking FIFO open so a dead player never deadlocks the test runner.
    deadline = time.time() + 10.0
    fd = None
    while time.time() < deadline:
        if p.poll() is not None:
            print(f"!! player exited early (code {p.returncode}) before opening ctl fifo")
            break
        try:
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as e:
            if e.errno != errno.ENXIO:
                raise
            time.sleep(0.05)

    if fd is not None:
        os.set_blocking(fd, True)
        w = os.fdopen(fd, "w", buffering=1)
        remaining = 1.2 - (time.time() - t_start)
        if remaining > 0:
            time.sleep(remaining)
        for step in script.split(";"):
            step = step.strip()
            if not step:
                continue
            try:
                time.sleep(float(step))
                continue
            except ValueError:
                pass
            if p.poll() is not None:
                print(f"!! player exited (code {p.returncode}) before '{step}'")
                break
            try:
                w.write(step + "\n")
                w.flush()
            except BrokenPipeError:
                print(f"!! broken pipe writing '{step}'")
                break
        time.sleep(0.3)
    elif p.poll() is None:
        print("!! timed out waiting for player to open ctl fifo")

    alive = p.poll() is None
    if alive:
        if w is not None:
            try:
                w.write("quit\n")
                w.flush()
            except BrokenPipeError:
                pass
        try:
            p.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    print(open(log).read() if os.path.exists(log) else "(no log)")
    print("exit code:", p.returncode, "| was alive at end:", alive)
    out = p.stdout.read().decode(errors="replace").strip()
    if out:
        print("stdout:", out[-1500:])
finally:
    if w is not None:
        try:
            w.close()
        except OSError:
            pass
    if p.poll() is None:
        p.kill()
        p.wait()
    shutil.rmtree(d, ignore_errors=True)
