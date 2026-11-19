{
  lib,
  stdenv,
  makeWrapper,
  curl,
  python3,
  rdma-core,
  cudaPackages,
  rocmPackages,
  autoAddDriverRunpath,

  src,
  version,

  # "cpu" | "cuda" | "rocm" | "metal"
  backend ? "cpu",

  # Upstream builds with -march=native / -mcpu=native. That is not reproducible
  # and breaks on any machine older than the builder, so pin a baseline.
  # Override with e.g. `cpuFlag = "-march=znver4"` for a machine-specific build.
  cpuFlag ?
    if stdenv.hostPlatform.isDarwin then
      "-mcpu=apple-m1"
    else if stdenv.hostPlatform.isx86_64 then
      "-march=x86-64-v3"
    else if stdenv.hostPlatform.isAarch64 then
      "-march=armv8.2-a+dotprod"
    else
      "",

  # nvcc -arch value. The sandbox has no GPU, so `native` cannot work here.
  # sm_89 (Ada) is upstream's documented generic example; sm_120/sm_121 also
  # switch on the Blackwell MXFP4 kernels.
  cudaArch ? "sm_89",

  # hipcc --offload-arch value. Upstream only targets Strix Halo.
  rocmArch ? "gfx1151",

  # ds4 dlopen()s libibverbs for RDMA tensor parallelism.
  rdmaSupport ? stdenv.hostPlatform.isLinux,
}:

assert lib.assertOneOf "backend" backend [
  "cpu"
  "cuda"
  "rocm"
  "metal"
];
assert backend == "metal" -> stdenv.hostPlatform.isDarwin;
assert (backend == "cuda" || backend == "rocm") -> stdenv.hostPlatform.isLinux;

let
  isCuda = backend == "cuda";
  isRocm = backend == "rocm";
  isMetal = backend == "metal";

  rocmLibs = with rocmPackages; [
    clr
    hipblas
    hipblas-common
    hipblaslt
    rocblas
    rocwmma
    hipcub
    rocprim
  ];

  binaries = [
    "ds4"
    "ds4-server"
    "ds4-bench"
    "ds4-eval"
    "ds4-agent"
  ];
in
stdenv.mkDerivation {
  pname = "ds4-${backend}";
  inherit version src;

  strictDeps = true;
  # Keeps make flags that contain spaces (CUDA_LDLIBS) as single arguments.
  __structuredAttrs = true;

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals isCuda [
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ]
  ++ lib.optionals isRocm [ rocmPackages.clr ];

  buildInputs =
    lib.optionals isCuda (
      with cudaPackages;
      [
        cuda_cudart
        cccl
        libcublas
      ]
    )
    ++ lib.optionals isRocm rocmLibs;

  postPatch = ''
    patchShebangs download_model.sh
  ''
  # The Metal runtime compiles its kernels at startup from metal/*.metal,
  # looked up relative to the working directory. Point it at the store copy.
  + lib.optionalString isMetal ''
    substituteInPlace ds4_metal.m \
      --replace-fail '@"metal/' '@"${placeholder "out"}/share/ds4/metal/'
  ''
  # The downloader assumes it lives in a writable checkout: it defaults to
  # ./gguf beside itself and symlinks ./ds4flash.gguf there. Make it work in
  # the caller's directory instead, keeping the one helper it needs in the store.
  + ''
    substituteInPlace download_model.sh \
      --replace-fail 'ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)' \
                     'ROOT=''${DS4_ROOT:-$PWD}' \
      --replace-fail '"$ROOT/gguf-tools/merge_deepseek41_shards.py"' \
                     '"${placeholder "out"}/share/ds4/gguf-tools/merge_deepseek41_shards.py"'
  '';

  enableParallelBuilding = true;

  makeFlags = [
    "CC=${stdenv.cc.targetPrefix}cc"
    "NATIVE_CPU_FLAG=${cpuFlag}"
    "DEBUG_FLAGS="
  ]
  ++ lib.optionals isCuda [
    "NVCC=nvcc"
    "CUDA_HOME=${cudaPackages.cuda_nvcc}"
    "CUDA_ARCH=${cudaArch}"
    # Upstream adds -L$(CUDA_HOME)/lib64; here the cc wrapper nvcc links with
    # already knows where cudart and cublas are.
    "CUDA_LDLIBS=-lm -Xcompiler -pthread -lcudart -lcublas"
  ]
  ++ lib.optionals isRocm [
    "HIPCC=hipcc"
    "ROCM_ARCH=${rocmArch}"
  ];

  buildFlags = [
    {
      cpu = "cpu";
      cuda = "cuda";
      rocm = "strix-halo";
      metal = "all";
    }
    .${backend}
  ];

  # hipcc drives an unwrapped clang, which does not see the stdenv's
  # NIX_CFLAGS_COMPILE / NIX_LDFLAGS, so feed it the search paths directly.
  env = lib.optionalAttrs isRocm {
    CPATH = lib.makeSearchPathOutput "dev" "include" rocmLibs;
    LIBRARY_PATH = lib.makeLibraryPath rocmLibs;
    NIX_LDFLAGS = "-rpath ${lib.makeLibraryPath rocmLibs}";
  };

  # Nearly all of `make test` needs a multi-GB GGUF and a GPU.
  doCheck = false;

  installPhase = ''
    runHook preInstall

    install -Dm755 -t $out/bin ${lib.concatStringsSep " " binaries}

    install -Dm755 download_model.sh $out/share/ds4/download_model.sh
    install -Dm644 -t $out/share/ds4/gguf-tools gguf-tools/merge_deepseek41_shards.py
    makeWrapper $out/share/ds4/download_model.sh $out/bin/ds4-download-model \
      --prefix PATH : ${
        lib.makeBinPath [
          curl
          python3
        ]
      }

    install -Dm644 -t $out/share/doc/ds4 README.md MODEL_CARD.md LICENSE docs/*.md
    install -Dm644 -t $out/share/doc/ds4/licenses licenses/*
  ''
  + lib.optionalString isMetal ''
    install -Dm644 -t $out/share/ds4/metal metal/*.metal
  ''
  + ''
    runHook postInstall
  '';

  postFixup = lib.optionalString (rdmaSupport && !isMetal) ''
    for b in ${lib.concatStringsSep " " binaries}; do
      patchelf --add-rpath ${lib.makeLibraryPath [ rdma-core ]} $out/bin/$b
    done
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ds4 --help > /dev/null
    $out/bin/ds4-server --help > /dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "DwarfStar: native inference engine for DeepSeek V4, GLM 5.x and Qwen3.8 GGUFs (${backend} backend)";
    homepage = "https://github.com/antirez/ds4";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "ds4";
    platforms =
      if isMetal then
        [ "aarch64-darwin" ]
      else if isRocm then
        [ "x86_64-linux" ]
      else if isCuda then
        lib.platforms.linux
      else
        lib.platforms.unix;
  };
}
