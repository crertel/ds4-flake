{
  description = "Nix packaging for DwarfStar (ds4), a narrow native inference engine for a few large open-weight models";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The engine itself. Bump with `nix flake update ds4-src`, or point at a
    # local checkout with `--override-input ds4-src path:../ds4`.
    ds4-src = {
      url = "github:crertel/ds4";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ds4-src,
    }:
    let
      inherit (nixpkgs) lib;

      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [ "aarch64-darwin" ];
      forSystems = systems: f: lib.genAttrs systems f;
      forAllSystems = forSystems (linuxSystems ++ darwinSystems);

      # Upstream has no tags, so follow the nixpkgs convention for untagged
      # sources: 0-unstable-YYYY-MM-DD from the pinned commit date.
      date = ds4-src.lastModifiedDate or "19700101";
      version = "0-unstable-${builtins.substring 0 4 date}-${builtins.substring 4 2 date}-${builtins.substring 6 2 date}";

      mkDs4 =
        pkgs: args:
        pkgs.callPackage ./package.nix (
          {
            src = ds4-src;
            inherit version;
          }
          // args
        );

      # CUDA is unfree, so it gets its own nixpkgs instance instead of forcing
      # allowUnfree on everything else.
      cudaPkgs =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };

      packagesFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isLinux = lib.elem system linuxSystems;
        in
        lib.optionalAttrs isLinux {
          ds4-cpu = mkDs4 pkgs { backend = "cpu"; };
          ds4-cuda = mkDs4 (cudaPkgs system) { backend = "cuda"; };
          # DGX Spark / GB10: enables the Blackwell-only MXFP4 kernels.
          ds4-cuda-spark = mkDs4 (cudaPkgs system) {
            backend = "cuda";
            cudaArch = "sm_121";
          };
          default = self.packages.${system}.ds4-cpu;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Strix Halo (gfx1151) by default; other cards via
          # `ds4-rocm.override { rocmArch = "gfx1030"; }` are untested upstream.
          ds4-rocm = mkDs4 pkgs { backend = "rocm"; };
        }
        // lib.optionalAttrs (!isLinux) {
          ds4-metal = mkDs4 pkgs { backend = "metal"; };
          ds4-cpu = mkDs4 pkgs { backend = "cpu"; };
          default = self.packages.${system}.ds4-metal;
        };
    in
    {
      packages = forAllSystems packagesFor;

      overlays.default = final: prev: {
        ds4 = mkDs4 final {
          backend =
            if final.stdenv.hostPlatform.isDarwin then
              "metal"
            else if final.config.cudaSupport or false then
              "cuda"
            else if final.config.rocmSupport or false then
              "rocm"
            else
              "cpu";
        };
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # For hacking on a ds4 checkout: `nix develop` here, then `make cpu`
          # (or `make` on macOS) over there.
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = [
              pkgs.python3
              pkgs.curl
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.gdb ];
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          rocm = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.ds4-rocm ];
            packages = [ pkgs.python3 ];
          };
        }
        // lib.optionalAttrs (lib.elem system linuxSystems) {
          cuda = (cudaPkgs system).mkShell {
            inputsFrom = [ self.packages.${system}.ds4-cuda ];
            packages = [ pkgs.python3 ];
          };
        }
      );

      checks = forSystems linuxSystems (system: {
        inherit (self.packages.${system}) ds4-cpu;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
