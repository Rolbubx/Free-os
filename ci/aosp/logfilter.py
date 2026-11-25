#!/usr/bin/env python3
"""Turns raw repo/ninja output into the FreeOS build log format.

    <command> 2>&1 | python3 -u logfilter.py PHASE RAW_LOG

  [HH:MM:SS, info]  current action, at most every ACTION_EVERY seconds
  [HH:MM:SS, warn]  warnings, at most every WARN_EVERY seconds (rest counted)
  [HH:MM:SS, error] errors and the output of a failed step, always, in full
  [HH:MM:SS, info]  progress + time left, every STATUS_EVERY seconds

Every raw line is also appended to RAW_LOG.
"""
import io
import os
import re
import sys
import threading
import time

# overridable for testing
ACTION_EVERY = float(os.environ.get("LOG_ACTION_EVERY", 10))
WARN_EVERY = float(os.environ.get("LOG_WARN_EVERY", 5))
STATUS_EVERY = float(os.environ.get("LOG_STATUS_EVERY", 30))

phase, raw_path = sys.argv[1], sys.argv[2]

# ninja/soong:  "[ 45% 12345/28000] //frameworks/base:framework javac"
NINJA = re.compile(r"^\[\s*(\d+)% (\d+)/(\d+)[^\]]*\]\s*(.*)")
# repo sync:    "Fetching: 45% (500/1100), done in 3m"
REPO = re.compile(r"^([A-Za-z][A-Za-z ]*?)(?: projects)?:\s+(\d+)% \((\d+)/(\d+)\)")
ERROR = re.compile(r"^FAILED:|^fatal:|^error:|\berror\b:|^ninja: build stopped|^#### failed", re.I)
WARNING = re.compile(r"\bwarning\b:", re.I)

lock = threading.Lock()
start = time.time()
state = {
    "done": 0, "total": 0,            # progress of the current ninja/repo run
    "seg_start": start, "seg_done0": 0,
    "last_action": "", "last_action_at": 0.0,
    "last_warn_at": 0.0, "warn_total": 0, "warn_hidden": 0,
    "errors": 0, "in_failure": False,
}


def emit(level, msg):
    print(f"[{time.strftime('%H:%M:%S')}, {level}] {msg}", flush=True)


def fmt(seconds):
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"


def status():
    now = time.time()
    elapsed = fmt(now - start)
    done, total = state["done"], state["total"]
    if total:
        moved = done - state["seg_done0"]
        rate = moved / max(now - state["seg_start"], 1e-6)
        left = f"about {fmt((total - done) / rate)} left" if moved > 0 else "estimating time left"
        msg = f"{phase}: {done * 100 // total}% ({done}/{total}), elapsed {elapsed}, {left}"
    else:
        msg = f"{phase}: working, elapsed {elapsed} (no progress counter yet)"
    if state["warn_hidden"]:
        msg += f", {state['warn_hidden']} more warnings in build.log"
        state["warn_hidden"] = 0
    emit("info", msg)


def ticker():
    while True:
        time.sleep(STATUS_EVERY)
        with lock:
            status()


def progress(done, total):
    if total != state["total"] or done < state["done"]:
        # a new ninja invocation (soong bootstrap, kati, main build) or repo stage
        state["total"], state["seg_start"], state["seg_done0"] = total, time.time(), done
    state["done"] = done


def handle(line):
    now = time.time()
    m = NINJA.match(line) or None
    action = None
    if m:
        state["in_failure"] = False
        progress(int(m.group(2)), int(m.group(3)))
        action = m.group(4)
    else:
        r = REPO.match(line)
        if r:
            progress(int(r.group(3)), int(r.group(4)))
            action = f"{r.group(1).strip()} {r.group(3)}/{r.group(4)}"

    if ERROR.search(line) or state["in_failure"]:
        if line.startswith("FAILED:"):
            state["in_failure"] = True    # show the failed step's output in full
        state["errors"] += 1
        emit("error", line)
        return
    if WARNING.search(line):
        state["warn_total"] += 1
        if now - state["last_warn_at"] >= WARN_EVERY:
            state["last_warn_at"] = now
            emit("warn", line)
        else:
            state["warn_hidden"] += 1
        return

    action = action or line
    state["last_action"] = action
    if action and now - state["last_action_at"] >= ACTION_EVERY:
        state["last_action_at"] = now
        emit("info", action)


def main():
    threading.Thread(target=ticker, daemon=True).start()
    emit("info", f"{phase}: started")
    # newline=None turns the '\r' progress redraws of repo/ninja into separate lines
    stream = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace", newline=None)
    with open(raw_path, "a", encoding="utf-8") as raw:
        for line in stream:
            raw.write(line)
            line = line.rstrip()
            if line:
                with lock:
                    handle(line)
    with lock:
        emit("info", f"{phase}: ended after {fmt(time.time() - start)}, "
                     f"{state['warn_total']} warnings, {state['errors']} error lines")


if __name__ == "__main__":
    main()
