"""PTY regression: python3 tests/manual/streaming_input.py [--root UPSTREAM_TREE].

Runs the real SSE replay/renderer while typing; records a fake ABC request rather
than touching the host input method. Requires nvim and deps/plenary.nvim.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args()
root = args.root.resolve()
scenario = Path(__file__).with_suffix(".lua").resolve()
with tempfile.TemporaryDirectory(prefix="opencode-stream-", dir=os.environ.get("TMPDIR")) as directory:
    report_path = Path(directory) / "report.json"
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", STREAM_TEST_ROOT=str(root),
               STREAM_TEST_REPORT=str(report_path))
    env.pop("VIM", None)
    env.pop("VIMRUNTIME", None)
    process = subprocess.Popen(
        ["nvim", "-u", "tests/minimal/init.lua", "-i", "NONE", "-n",
         "-c", "luafile " + str(scenario)],
        cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave,
    )
    os.close(slave)
    typed = ""
    transcript = bytearray()

    def checkpoint(predicate, typing=False):
        global typed
        deadline = time.monotonic() + 8
        next_key = time.monotonic()
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], .01)
            if readable:
                transcript.extend(os.read(master, 65536))
            if report_path.exists():
                report = json.loads(report_path.read_text())
                assert not report.get("error"), report.get("error")
                if predicate(report):
                    return report
            if typing and time.monotonic() >= next_key:
                os.write(master, "中x".encode())
                typed += "中x"
                next_key = time.monotonic() + .01
        raise AssertionError("terminal checkpoint timeout: " + repr(bytes(transcript[-1500:])))

    try:
        report = checkpoint(lambda r: r["phase"] == 0)
        assert report["terminal"]
        for phase in range(1, report["events"] + 1):
            os.write(master, b"\x1b[15~")
            report = checkpoint(lambda r: r["phase"] == phase, typing=True)
            assert report["mode"] == "i" and report["focused"], report
            assert report["requests"] == [], report
            assert report["focus_events"] == [], report
            assert report["internal_normal_keys"] == [], report
        # A final key is a fence: all preceding terminal text must be present.
        os.write(master, b"\x1b")
        os.write(master, b"\x1b[17~")
        report = checkpoint(lambda r: r["mode"] == "n")
        assert report["input"] == typed, (len(report["input"]), len(typed))
        assert len(report["requests"]) == 1 and report["requests"][0]["buf"] == report["input_buf"], report
        assert max(c["closed"] for c in report["checkpoints"]) > 0, report
        assert report["remaining_tools"] == 1, report
        print(json.dumps({"passed": True, "events": report["events"], "typed_bytes": len(typed.encode()),
                          "maintenance_ABC_requests": 0, "intentional_Esc_requests": 1,
                          "internal_normal_keys": report["internal_normal_keys"],
                          "checkpoints": report["checkpoints"]}, indent=2))
    finally:
        process.kill()
        process.wait(timeout=5)
        os.close(master)
