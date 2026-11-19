# Status

Last checked 2026-11-18 against ds4 `b3f5018` and nixpkgs `0490633`
(CUDA 13.5, ROCm 7.2.4), building on x86_64-linux.

| Package | Evaluates | Builds | `--help` runs | Inference run |
|---|---|---|---|---|
| `ds4-cpu` (x86_64-linux) | yes | yes | yes | no |
| `ds4-cuda` (x86_64-linux, `sm_89`) | yes | yes | yes | no |
| `ds4-cuda-spark` (x86_64-linux, `sm_121`) | yes | yes | yes | no |
| `ds4-rocm` (x86_64-linux, `gfx1151`) | yes | yes | yes | no |
| `ds4-cuda-spark` (aarch64-linux) | yes | not tried | | |
| `ds4-cpu` (aarch64-linux) | not tried | not tried | | |
| `ds4-metal` (aarch64-darwin) | yes | not tried | | |
| `ds4-cpu` (aarch64-darwin) | yes | not tried | | |

Nothing has been run against a model yet. "Builds" means the binaries compile,
link against the Nix store copies of their GPU libraries, and print their help
text.

## Known gaps

- **Metal** has never been built. The shader path patch in `package.nix`
  (`metal/…` to `$out/share/ds4/metal/…`) is written from reading
  `ds4_metal.m`, not from a run.
- **aarch64-linux** (the real DGX Spark target) has not been built; only the
  `sm_121` code path was compiled, on x86_64.
- **ROCm on anything but gfx1151** is an override, not a supported target.
- `ds4-download-model` still prints `./download_model.sh` in its usage text.
- The agent's web tool finds Chrome through `DS4_CHROME`, then `/usr/bin/...`,
  then `PATH`. On NixOS only the first and last can work.
