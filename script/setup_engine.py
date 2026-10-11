#!/usr/bin/env python3
"""Install pinned, checksum-verified upstream runtime assets."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "Runtime"
MANIFEST = ROOT / "Resources/runtime-assets.json"


def verify_file(path, digest):
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            sha.update(chunk)
    if sha.hexdigest() != digest.removeprefix("sha256:"):
        raise RuntimeError(f"Checksum mismatch; refusing asset: {path.name}")


def download(url, destination, digest=None):
    temporary = destination.with_suffix(destination.suffix + ".partial")
    try:
        subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "20",
                        "-o", str(temporary), url], check=True)
        if digest:
            verify_file(temporary, digest)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def extract_archive(archive, destination):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as handle:
            for name in handle.namelist():
                if not (destination / name).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError("Unsafe archive path")
            handle.extractall(destination)
    else:
        with tarfile.open(archive) as handle:
            handle.extractall(destination, filter="data")


def runtime_metadata(asset):
    return {"tag": asset["tag"], "asset": asset["asset"],
            "sha256": "sha256:" + asset["sha256"]}


def verify_installation(assets):
    runtime = RUNTIME / "runtime-version.json"
    model = RUNTIME / "model-version.json"
    if not (RUNTIME / "engine/llama-server").is_file():
        raise RuntimeError("Runtime missing; run python3 script/setup_engine.py")
    if not runtime.is_file() or json.loads(runtime.read_text()) != runtime_metadata(assets["runtime"]):
        raise RuntimeError("Installed runtime provenance does not match the pinned manifest")
    if not model.is_file() or json.loads(model.read_text()) != assets["model"]:
        raise RuntimeError("Installed model provenance does not match the pinned manifest")
    verify_file(RUNTIME / assets["model"]["file"], assets["model"]["sha256"])
    for name in ["Qwen-LICENSE", "llama.cpp-LICENSE"]:
        expected = hashlib.sha256((ROOT / "Resources/licenses" / name).read_bytes()).hexdigest()
        verify_file(RUNTIME / "licenses" / name, expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true",
                        help="Check installed provenance, weights and licenses without downloads")
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        raise RuntimeError("Python 3.12 or later is required")
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("The bundled runtime currently supports Apple Silicon macOS only")
    assets = json.loads(MANIFEST.read_text())
    if args.verify_only:
        verify_installation(assets)
        print("Pinned runtime and model verified.", flush=True)
        return
    RUNTIME.mkdir(exist_ok=True)
    engine = RUNTIME / "engine"
    if not (engine / "llama-server").exists():
        asset = assets["runtime"]
        archive = RUNTIME / asset["asset"]
        print(f"Runtime: {asset['tag']} / {asset['asset']}", flush=True)
        download(asset["url"], archive, asset["sha256"])
        with tempfile.TemporaryDirectory(prefix="unpack-", dir=RUNTIME) as directory:
            unpack = Path(directory)
            extract_archive(archive, unpack)
            binaries = list(unpack.rglob("llama-server"))
            if len(binaries) != 1:
                raise RuntimeError("Expected exactly one llama-server in runtime archive")
            shutil.copytree(binaries[0].parent, engine, dirs_exist_ok=True)
            (engine / "llama-server").chmod(0o755)
        (RUNTIME / "runtime-version.json").write_text(json.dumps(runtime_metadata(asset), indent=2) + "\n")
        archive.unlink()

    model_asset = assets["model"]
    model = RUNTIME / model_asset["file"]
    if not model.exists():
        print(f"Model: {model_asset['repo']} / {model_asset['file']}", flush=True)
        download(f"https://huggingface.co/{model_asset['repo']}/resolve/"
                 f"{model_asset['revision']}/{model_asset['file']}", model, model_asset["sha256"])
        (RUNTIME / "model-version.json").write_text(json.dumps(model_asset, indent=2) + "\n")
    notices = RUNTIME / "licenses"
    notices.mkdir(exist_ok=True)
    for name in ["Qwen-LICENSE", "llama.cpp-LICENSE"]:
        shutil.copy2(ROOT / "Resources/licenses" / name, notices / name)
    verify_installation(assets)
    print("Pinned independent local runtime ready.", flush=True)


if __name__ == "__main__":
    main()
