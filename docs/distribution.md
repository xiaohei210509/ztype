# Distribution

The public release is a separate optimized Apple Silicon build. It does not
reuse the installed development bundle or its certificate. Packaging never
launches, registers, replaces, or changes permissions for the installed app.

## Produce A Disk Image

```bash
python3 script/setup_engine.py
./script/test.sh
python3 -m unittest discover -s script/tests -v
./script/package_dmg.sh
```

The script verifies runtime/model provenance, builds the release executable,
creates a new application bundle in temporary staging, includes upstream
licenses and the original app license, verifies the signature, and creates
`dist/ztype-<version>-arm64.dmg` plus a `.sha256` checksum.

Only the pinned production runtime and model are packaged. Experiments,
documents, logs, certificates, and developer settings are excluded.
The disk image contains `ztype.app`, an `Applications` shortcut, and installation
notes. Model inclusion makes the download large but avoids a separate first-run
download.

## Signing

The initial release is **ad-hoc signed and not notarized**. This is not equivalent
to Developer ID distribution. Downloaded copies can be blocked by Gatekeeper,
and ad-hoc updates may require regranting Accessibility and Input Monitoring
permission. Never tell users to disable Gatekeeper or reset TCC.

`ZTYPE_DISTRIBUTION_IDENTITY` can explicitly select a distribution identity for
future packaging. The script does not discover or reuse a personal development
certificate. Adding a Developer ID signature does not itself notarize the app;
notarization and ticket stapling remain separate, unimplemented release steps.
Do not describe the initial DMG as notarized.

## Verify The Finished Image

```bash
hdiutil verify dist/ztype-0.1.0-arm64.dmg
cd dist
shasum -a 256 -c ztype-0.1.0-arm64.dmg.sha256
```

Inspect a read-only mounted copy with `codesign --verify --deep --strict` and
`swift script/verify_app.swift <mounted-app-path>` before publishing.
Do not launch or authorize the mounted copy. Verify a private extraction or
fixture separately if runtime checks are required.

## Release Contents

- Tag matching the app's `CFBundleShortVersionString`.
- A complete DMG and matching SHA-256 checksum.
- Minimum OS/architecture, install instructions, permission requirements,
  dependency licenses, and honest signing/compatibility limitations.
- The source commit used to compile the artifact.
