{
  description = "Lightweight eval tests for modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      # helper function to read JSON
      loadJSON = path: builtins.fromJSON (builtins.readFile path);

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
          snapshotSource ? null, # function cfg -> attrset to snapshot; null keeps legacy config.snapshot
          snapshotFilter ? defaultSnapshotFilter,
        }:
        let
          # Only include snapshotModule for simple eval tests, not full NixOS builds
          baseModules = [ snapshotModule ] ++ (if nixosBuild then [ bootMinimal ] else [ ]);

          evalResult =
            if nixosBuild then
              lib.nixosSystem {
                inherit (pkgs) system;
                modules = baseModules ++ modules;
              }
            else
              pkgs.lib.evalModules {
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

          toplevel = if nixosBuild then evalResult.config.system.build.toplevel else null;
        in
        {
          check = checkDrv;
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

      defaultSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      evalTestsOption = nixpkgs.lib.mkOption {
        type = nixpkgs.lib.types.attrsOf (
          nixpkgs.lib.types.submodule {
            options = {
              modules = nixpkgs.lib.mkOption {
                type = nixpkgs.lib.types.listOf nixpkgs.lib.types.anything;
                description = "List of modules to evaluate.";
              };
              outputDir = nixpkgs.lib.mkOption {
                type = nixpkgs.lib.types.str;
                default = ".";
              };
              nixosBuild = nixpkgs.lib.mkOption {
                type = nixpkgs.lib.types.bool;
                default = false;
                description = "Whether to evaluate as a full NixOS system and expose the toplevel build artifact.";
              };
              snapshotSource = nixpkgs.lib.mkOption {
                type = nixpkgs.lib.types.nullOr nixpkgs.lib.types.unspecified;
                default = null;
                description = ''
                  Function `cfg: <attrset>` used to compute the snapshot from the evaluated config.
                                If null, the module must set `config.snapshot` itself (legacy behavior).'';
              };
              snapshotFilter = nixpkgs.lib.mkOption {
                type = nixpkgs.lib.types.functionTo nixpkgs.lib.types.attrs;
                default = defaultSnapshotFilter;
                description = ''
                  Filter applied to the snapshot output to strip heavy/unprintable values.
                                Defaults to removing functions and derivations recursively.'';
              };
            };
          }
        );
        default = { };
      };

      flakeModule =
        { inputs, ... }:
        {
          perSystem =
            {
              config,
              pkgs,
              lib,
              ...
            }:
            let
              results = lib.mapAttrs (
                name: test:
                mkEvalOutput {
                  inherit pkgs name;
                  inherit (test)
                    modules
                    outputDir
                    nixosBuild
                    snapshotSource
                    snapshotFilter
                    ;
                  lib = inputs.nixpkgs.lib;
                }
              ) config.nix-eval.tests;

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
              options.nix-eval.tests = evalTestsOption;

              config = {
                checks = lib.mapAttrs (n: v: v.check) results;
                packages = lib.foldl' (acc: v: acc // v.packages) { } (lib.attrValues results);
                apps = lib.mapAttrs (n: v: v.app) results // {
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

                # Using legacyPackages for NixOS configurations as they are per-system here
                legacyPackages.nixosConfigurations = lib.mapAttrs (n: v: v.nixosConfiguration) (
                  lib.filterAttrs (n: v: v.nixosConfiguration != null) results
                );
              };
            };
        };

      mkFlake =
        {
          inputs,
          tests ? { },
          systems ? defaultSystems,
        }:
        flake-parts.lib.mkFlake { inherit inputs; } {
          imports = [ flakeModule ];
          inherit systems;
          perSystem =
            { ... }:
            {
              nix-eval.tests = tests;
            };
        };
    in
    {
      lib = {
        inherit
          mkEvalOutput
          snapshotModule
          flakeModule
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
