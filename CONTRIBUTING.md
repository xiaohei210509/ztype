# Contributing

Please open an issue for a bug or focused improvement, or send a pull request.
Contributions to the original project code are made under the MIT license.

## Development

- Apple Silicon, macOS 14 or later, Swift 6 or later.
- Python 3.12 or later for runtime setup, packaging checks, and benchmarks.
- `./script/test.sh` runs the Swift Testing suite without downloading a model.
- `python3 -m unittest discover -s script/tests` tests the setup helper.
- `python3 script/setup_engine.py` installs pinned, checksum-verified runtime assets.
- `./script/build_and_run.sh --verify` builds and launches the app.

## Scope

Keep fixes focused. Cross-app compatibility should follow advertised editor
capabilities rather than branches keyed to app names. Preserve target/context
validation, explicit acceptance, bounded retries, and cancellation.

Add regressions for changed acceptance, geometry, input routing, clipboard, or
inference behavior. Check that consecutive Tabs reuse the original remainder and
that actual user edits invalidate it. Do not silently change language or resource
policies to make a test pass.

## Bug Reports

Include macOS version, CPU architecture, ztype version, target app/version, input
source, permission/Tab readiness, steps, and expected versus observed behavior.
Use a scratch document. Redact private text and clipboard content from recordings
and logs before posting.

Do not commit model weights, generated applications, disk images, certificates,
credentials, or personal documents. Avoid logging document text or suggestions.
Describe native fixture results separately from real third-party editor results.

## Distribution

Use `./script/package_dmg.sh`, not the installed development app, for release
artifacts. Keep notarization status, architecture, third-party licenses, and
download checksums explicit. See [distribution notes](docs/distribution.md).
