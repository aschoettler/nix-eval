{
  description = "Lightweight eval tests for modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      ...
    }:
    let
      # helper function to read JSON
      loadJSON = path: builtins.fromJSON (builtins.readFile path);

      defaultSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      bootMinimal = {
        boot.loader.grub.device = "nodev";
        fileSystems."/" = {
          device = "/dev/disk/by-label/ROOT";
          fsType = "ext4";
        };
        system.stateVersion = "25.05";
      };

      snapshotModule = {
        options.snapshot = nixpkgs.lib.mkOption {
          type = nixpkgs.lib.types.attrsOf nixpkgs.lib.types.anything;
          default = { };
          description = "Container for anything. You can put whatever you want here.";
        };
      };

      # Aggressive default filter to keep snapshots lightweight and printable.
      # Drops any functions or derivations anywhere in the tree.
      defaultSnapshotFilter =
        let
          dropNames = [
            "passthru"
            "assertions"
            "warnings"
            "hostConf"
          ];
          sanitize =
            value:
            let
              attempted = builtins.tryEval value;
            in
            if !attempted.success then
              "<error>"
            else if builtins.isFunction attempted.value then
              "<function>"
            else if nixpkgs.lib.isDerivation attempted.value then
              "<derivation>"
            else if builtins.isAttrs attempted.value then
              nixpkgs.lib.mapAttrs (n: v: sanitize v) (nixpkgs.lib.removeAttrs attempted.value dropNames)
            else if builtins.isList attempted.value then
              map sanitize attempted.value
            else
              attempted.value;
        in
        sanitize;

      mkEvalOutput =
        {
          pkgs,
          lib,
          name,
          modules,
          outputDir,
          nixosBuild,
          specialArgs ? { },
          snapshotSource ? null, # function cfg -> attrset to snapshot; null keeps legacy config.snapshot
          snapshotFilter ? defaultSnapshotFilter,
          strictConfigCheck ? false,
        }:
        let
          # Only include snapshotModule for simple eval tests, not full NixOS builds
          baseModules = [ snapshotModule ] ++ (if nixosBuild then [ bootMinimal ] else [ ]);

          # Mirror key NixOS module arguments in eval mode so snapshot modules can
          # still reference `pkgs`/`lib` after conversion.
          mergedSpecialArgs = {
            inherit pkgs lib;
          } // specialArgs;

          evalResult =
            if nixosBuild then
              lib.nixosSystem {
                inherit (pkgs) system;
                specialArgs = mergedSpecialArgs;
                modules = baseModules ++ modules;
              }
            else
              pkgs.lib.evalModules {
                specialArgs = mergedSpecialArgs;
                modules = baseModules ++ modules;
              };

          snapshot =
            if snapshotSource == null then
              evalResult.config.snapshot
            else
              snapshotFilter (snapshotSource evalResult.config);

          pretty = lib.generators.toPretty { } snapshot;
          jsonText = builtins.toJSON snapshot;
          nixDrv = pkgs.writeText "${name}.nix" pretty;
          jsonDrv = pkgs.writeText "${name}.json" jsonText;

          appDrv = pkgs.writeShellApplication {
            name = "write-${name}";
            text = ''
              cat ${nixDrv} > ${outputDir}/${name}.out.nix
              echo "Wrote ${outputDir}/${name}.out.nix"
            '';
          };

          checkDrv = pkgs.runCommand "${name}-check" { inherit nixDrv; } ''
            echo "Wrote result -> $eval_pretty_drv" # store path to written text
            ln -s "$nixDrv" "$out"
          '';

          strictCheckDrv =
            if !strictConfigCheck then
              null
            else
              let
                # Avoid forcing the internal module metadata; it can contain large structures (e.g. pkgs).
                configForCheck = builtins.removeAttrs evalResult.config [
                  "_module"
                  "snapshot"
                ];
                forced = builtins.tryEval (builtins.deepSeq configForCheck true);
              in
              pkgs.runCommand "${name}-strict-config-check"
                {
                  strictSuccess = if forced.success then "1" else "0";
                }
                ''
                  if [ "$strictSuccess" = "1" ]; then
                    echo "ok" > "$out"
                  else
                    echo "Strict config check failed: deepSeq(config) hit an evaluation error" >&2
                    exit 1
                  fi
                '';

          toplevel = if nixosBuild then evalResult.config.system.build.toplevel else null;
        in
        {
          check = checkDrv;
          checkStrictConfig = strictCheckDrv;
          packages = {
            "${name}-nix" = nixDrv;
            "${name}-json" = jsonDrv;
          }
          // (if nixosBuild then { "${name}-toplevel" = toplevel; } else { });
          app = {
            type = "app";
            program = "${appDrv}/bin/write-${name}";
            meta.description = "Emit ${name} snapshot";
          };
          nixosConfiguration = if nixosBuild then evalResult else null;
        };
      mkFlake =
        {
          inputs,
          tests ? { },
          systems ? defaultSystems,
        }:
        let
          lib = inputs.nixpkgs.lib;

          perSystem =
            system:
            let
              pkgs = inputs.nixpkgs.legacyPackages.${system};

              results = lib.mapAttrs (
                name: test:
                mkEvalOutput {
                  inherit pkgs lib name;
                  modules = test.modules;
                  outputDir = test.outputDir or ".";
                  nixosBuild = test.nixosBuild or false;
                  specialArgs = test.specialArgs or { };
                  snapshotSource = test.snapshotSource or null;
                  snapshotFilter = test.snapshotFilter or defaultSnapshotFilter;
                  strictConfigCheck = test.strictConfigCheck or false;
                }
              ) tests;

              runAll = pkgs.writeShellApplication {
                name = "run-all";
                text = builtins.concatStringsSep "\n" (
                  lib.mapAttrsToList (name: result: ''
                    echo "Running ${name}..."
                    ${result.app.program}
                    ${lib.optionalString (result.packages ? "${name}-toplevel") ''
                      # Force realization of the toplevel derivation for boot tests (nixosBuild = true)
                      echo "Realizing ${name}-toplevel..."
                      # realpath ${result.packages."${name}-toplevel"} >/dev/null
                      realpath ${result.packages."${name}-toplevel"}
                    ''}
                  '') results
                );
              };
            in
            {
              checks =
                (lib.mapAttrs (_: v: v.check) results)
                // (lib.mapAttrs' (n: v: lib.nameValuePair "${n}-strict-config" v.checkStrictConfig) (
                  lib.filterAttrs (_: v: v.checkStrictConfig != null) results
                ));
              packages = lib.foldl' (acc: v: acc // v.packages) { } (lib.attrValues results);
              apps = lib.mapAttrs (_: v: v.app) results // {
                all = {
                  type = "app";
                  program = "${runAll}/bin/run-all";
                  meta.description = "Run all eval tests";
                };

                convert = {
                  type = "app";
                  program =
                    toString (
                      pkgs.writeShellApplication {
                        name = "nix-eval-convert";
                        runtimeInputs = [ pkgs.python3 ];
                        text = ''
                          set -euo pipefail
                          python3 ${./converter/convert_config_passthru.py} "$@"
                        '';
                      }
                    )
                    + "/bin/nix-eval-convert";
                  meta.description = "Rewrite modules' top-level config to config.snapshot.<name>";
                };

                convert-and-test = {
                  type = "app";
                  program =
                    toString (
                      pkgs.writeShellApplication {
                        name = "nix-eval-convert-and-test";
                        runtimeInputs = [
                          pkgs.coreutils
                          pkgs.findutils
                          pkgs.nix
                          pkgs.bash
                          pkgs.python3
                        ];
                        text = ''
                          set -euo pipefail
                          mkdir -p modules modules-converted
                          if ls modules 1>/dev/null 2>&1; then
                            cp -r modules/* modules-converted/ 2>/dev/null || true
                          fi
                          nix run .#convert -- modules-converted
                          nix flake check
                          nix run .#all
                        '';
                      }
                    )
                    + "/bin/nix-eval-convert-and-test";
                  meta.description = "Convert modules, flake check, then run all apps";
                };
              };

              legacyPackages.nixosConfigurations = lib.mapAttrs (_: v: v.nixosConfiguration) (
                lib.filterAttrs (_: v: v.nixosConfiguration != null) results
              );
            };

          perSystemResults = lib.genAttrs systems perSystem;
        in
        {
          checks = lib.mapAttrs (_: v: v.checks) perSystemResults;
          packages = lib.mapAttrs (_: v: v.packages) perSystemResults;
          apps = lib.mapAttrs (_: v: v.apps) perSystemResults;
          legacyPackages = lib.mapAttrs (_: v: v.legacyPackages) perSystemResults;
        };
    in
    {
      lib = {
        inherit
          mkEvalOutput
          snapshotModule
          loadJSON
          mkFlake
          bootMinimal
          ;
      };

      templates = rec {
        module-test = {
          description = "Ad-hoc module test harness (build + snapshot)";
          path = ./templates/module-test;
        };
        default = module-test;
      };

      apps = nixpkgs.lib.genAttrs defaultSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          template-init = {
            type = "app";
            program =
              toString (
                pkgs.writeShellApplication {
                  name = "nix-eval-template-init";
                  text = ''
                    set -euo pipefail
                    target="${self}"#module-test
                    nix flake init -t "$target" --refresh
                  '';
                }
              )
              + "/bin/nix-eval-template-init";
            meta.description = "Initialize a module-test workspace from the nix-eval template";
          };
          default = template-init;
        }
      );

    };
}
