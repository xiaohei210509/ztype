import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import setup_engine


class SetupTests(unittest.TestCase):
    def test_checksum_accepts_plain_and_prefixed_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asset"
            path.write_bytes(b"verified runtime")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            setup_engine.verify_file(path, digest)
            setup_engine.verify_file(path, "sha256:" + digest)
            with self.assertRaises(RuntimeError):
                setup_engine.verify_file(path, "0" * 64)

    def test_bad_download_does_not_replace_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "asset"
            destination.write_bytes(b"existing")

            def fake_curl(command, **kwargs):
                Path(command[command.index("-o") + 1]).write_bytes(b"wrong download")

            with patch.object(setup_engine.subprocess, "run", side_effect=fake_curl):
                with self.assertRaises(RuntimeError):
                    setup_engine.download("https://example.invalid/asset", destination, "0" * 64)
            self.assertEqual(destination.read_bytes(), b"existing")
            self.assertFalse(destination.with_suffix(".partial").exists())

    def test_runtime_metadata_uses_the_pinned_version(self):
        asset = {"tag": "b123", "asset": "runtime.tar.gz", "sha256": "a" * 64}
        self.assertEqual(setup_engine.runtime_metadata(asset), {
            "tag": "b123", "asset": "runtime.tar.gz", "sha256": "sha256:" + "a" * 64
        })

    def test_zip_cannot_escape_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "asset.zip"
            staging = root / "staging"
            staging.mkdir()
            with zipfile.ZipFile(archive, "w") as handle:
                handle.writestr("../escaped", "unsafe")
            with self.assertRaises(RuntimeError):
                setup_engine.extract_archive(archive, staging)
            self.assertFalse((root / "escaped").exists())

    def test_tar_cannot_escape_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "asset.tar.gz"
            staging = root / "staging"
            staging.mkdir()
            with tarfile.open(archive, "w:gz") as handle:
                entry = tarfile.TarInfo("../escaped")
                entry.size = 6
                handle.addfile(entry, io.BytesIO(b"unsafe"))
            with self.assertRaises(tarfile.FilterError):
                setup_engine.extract_archive(archive, staging)
            self.assertFalse((root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()
