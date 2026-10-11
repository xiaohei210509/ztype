#!/usr/bin/env python3
"""Measure the actual local runtime without reading user documents."""
import argparse
import json
from pathlib import Path
import secrets
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path.home() / "Library/Caches/ztype/Build"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", "build", "--scratch-path", str(BUILD)], cwd=ROOT, check=True)
    binary_dir = subprocess.check_output(
        ["swift", "build", "--scratch-path", str(BUILD), "--show-bin-path"],
        cwd=ROOT, text=True).strip()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    key = secrets.token_hex(24)
    process = subprocess.Popen([
        str(ROOT / "Runtime/engine/llama-server"),
        "-m", str(ROOT / "Runtime/Qwen3-1.7B-Q8_0.gguf"),
        "--host", "127.0.0.1", "--port", str(port), "--api-key", key,
        "-c", "2048", "-ngl", "99", "-t", "3", "-tb", "3", "--parallel", "1",
        "--poll", "0", "--poll-batch", "0", "--prio", "-1",
        "-b", "256", "-ub", "128", "--no-webui", "--log-disable"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    start = time.monotonic()
    try:
        for _ in range(150):
            if process.poll() is not None:
                raise RuntimeError("Runtime exited before becoming ready")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
                    if json.load(response)["status"] == "ok":
                        break
            except Exception:
                time.sleep(0.1)
        else:
            raise RuntimeError("Runtime readiness timed out")
        print(f"Cold model load: {(time.monotonic() - start) * 1000:.0f} ms", flush=True)
        command = [str(Path(binary_dir) / "ztypeBench"), str(port), key]
        if args.output:
            command.append(str(args.output.resolve()))
        subprocess.run(command, check=True)
        print("Idle samples (second sample is the interval measurement):", flush=True)
        subprocess.run(["top", "-l", "2", "-s", "5", "-pid", str(process.pid),
                        "-stats", "pid,command,cpu,mem,threads"], check=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
