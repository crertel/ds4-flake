# ds4-flake

Nix packaging for [DwarfStar (ds4)](https://github.com/antirez/ds4), a narrow
native inference engine for DeepSeek V4, GLM 5.x and Qwen3.8 GGUFs.

The engine source is a flake input pinned to
[crertel/ds4](https://github.com/crertel/ds4), a fork of upstream. Nothing here
patches the engine's behaviour; the packaging only fixes paths and build flags.

## Packages

| Output | Systems | Backend |
|---|---|---|
| `ds4-cpu` | Linux, macOS | CPU only. Upstream treats this as reference/debug code. |
| `ds4-cuda` | Linux | CUDA, built for `sm_89` (Ada). Unfree. |
| `ds4-cuda-spark` | Linux | CUDA for DGX Spark / GB10 (`sm_121`), with the MXFP4 kernels. Unfree. |
| `ds4-rocm` | x86_64-linux | ROCm, built for Strix Halo (`gfx1151`). |
| `ds4-metal` | aarch64-darwin | Metal. The primary upstream target. |

`default` is `ds4-metal` on macOS and `ds4-cpu` on Linux.

Each package installs `ds4`, `ds4-server`, `ds4-bench`, `ds4-eval`, `ds4-agent`
and `ds4-download-model`.

```sh
nix build github:crertel/ds4-flake#ds4-cpu
nix run   github:crertel/ds4-flake#ds4-cpu -- --help
```

## Getting a model

`ds4-download-model` is upstream's `download_model.sh`, changed to work in the
current directory instead of beside the script: it downloads into `./gguf` and
links `./ds4flash.gguf`, which is where `ds4` looks by default.

```sh
mkdir ~/ds4 && cd ~/ds4
ds4-download-model            # lists the available models
ds4-download-model ds4f-q2
ds4
```

Set `DS4_GGUF_DIR` to download elsewhere, and `DS4_ROOT` to change where the
`ds4flash.gguf` link goes.

## Tuning the build

Upstream compiles with `-march=native`. These packages pin a baseline instead
(`x86-64-v3`, `armv8.2-a+dotprod`, `apple-m1`) so the result runs on machines
other than the builder. Override it if you want a machine-specific build:

```nix
ds4-flake.packages.${system}.ds4-cuda.override {
  cpuFlag = "-march=znver4";
  cudaArch = "sm_120";   # nvcc -arch
}
```

```nix
ds4-flake.packages.${system}.ds4-rocm.override {
  rocmArch = "gfx1030";  # hipcc --offload-arch; only gfx1151 is tested upstream
}
```

## Overlay

`overlays.default` adds `pkgs.ds4`, picking the backend from the platform and
the nixpkgs config (`cudaSupport`, `rocmSupport`), falling back to CPU.

## Dev shells

For working on a ds4 checkout:

```sh
nix develop github:crertel/ds4-flake          # then: make cpu   (make on macOS)
nix develop github:crertel/ds4-flake#cuda     # then: make cuda CUDA_ARCH=sm_89
nix develop github:crertel/ds4-flake#rocm     # then: make strix-halo
```

## Updating

```sh
nix flake update ds4-src     # follow the fork's main branch
nix build .#ds4-cpu
```

To build against a local checkout without touching the lock file:

```sh
nix build .#ds4-cpu --override-input ds4-src path:../ds4
```

## What is and isn't tested

The build's own check only runs `ds4 --help` and `ds4-server --help`. Upstream's
`make test` needs a multi-GB GGUF and a GPU, so it is not run in the sandbox.

See [STATUS.md](STATUS.md) for which backends have been built and run.
