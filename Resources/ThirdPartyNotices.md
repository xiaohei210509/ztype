# Third-Party Notices

ztype is an independent application. It is not affiliated with Cotypist, Qwen,
or ggml-org, and does not incorporate another autocomplete application's code.

Original ztype source is distributed under the MIT license in the root `LICENSE`
file. That license does not replace the licenses of the following dependencies.

The packaged inference runtime is llama.cpp, copyright its contributors,
distributed under the MIT license. The full upstream notice is included in
`Resources/licenses/llama.cpp-LICENSE` in the source repository and
`licenses/llama.cpp-LICENSE` in the installed app.

The packaged model is Qwen3-1.7B-Q8_0 from the official Qwen/Qwen3-1.7B-GGUF
repository, distributed under Apache License 2.0. Its license is included in
`Resources/licenses/Qwen-LICENSE` in the source repository and
`licenses/Qwen-LICENSE` in the installed app. No claim of ownership is made over
these weights. Experimental model weights are not distributed.

Model and runtime provenance, versions, and download checksums are pinned in
`Resources/runtime-assets.json`. Setup also records them in
`Runtime/model-version.json` and `Runtime/runtime-version.json`.
