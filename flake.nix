{
  description = "Hydra demo";
  nixConfig.bash-prompt = "\\[\\e[0m\\][\\[\\e[0;2m\\]nix-develop \\[\\e[0;1m\\]Hydra-Demo \\[\\e[0;93m\\]\\w\\[\\e[0m\\]]\\[\\e[0m\\]$ \\[\\e[0m\\]";

  inputs = {

    haskell-nix.url = "github:input-output-hk/haskell.nix";
    iohk-nix.url = "github:input-output-hk/iohk-nix";
    iohk-nix.flake = false;
    nixpkgs.follows = "haskell-nix/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # all inputs below here are for pinning with haskell.nix
    cardano-addresses = {
      url =
        "github:input-output-hk/cardano-addresses/b6f2f3cef01a399376064194fd96711a5bdba4a7";
      flake = false;
    };
    cardano-base = {
      url =
        "github:input-output-hk/cardano-base/0f3a867493059e650cda69e20a5cbf1ace289a57";
      flake = false;
    };
    cardano-config = {
      url =
        "github:input-output-hk/cardano-config/1646e9167fab36c0bff82317743b96efa2d3adaa";
      flake = false;
    };
    cardano-crypto = {
      url =
        "github:input-output-hk/cardano-crypto/f73079303f663e028288f9f4a9e08bcca39a923e";
      flake = false;
    };
    cardano-ledger = {
      url =
        "github:input-output-hk/cardano-ledger/ce3057e0863304ccb3f79d78c77136219dc786c6";
      flake = false;
    };
    cardano-node = {
      url =
        "github:input-output-hk/cardano-node/1.35.0";
      flake = false; # we need it to be available in shell
    };
    cardano-prelude = {
      url =
        "github:input-output-hk/cardano-prelude/bb4ed71ba8e587f672d06edf9d2e376f4b055555";
      flake = false;
    };
    cardano-wallet = {
      url = "github:input-output-hk/cardano-wallet/a73d8c9717dc4e174745f8568d6f3fe84f0f9d76";
      flake = false;
    };
    ekg-forward = {
      url = "github:input-output-hk/ekg-forward/297cd9db5074339a2fb2e5ae7d0780debb670c63";
      flake = false;
    };
    ekg-json = {
      url = "github:vshabanov/ekg-json/00ebe7211c981686e65730b7144fbf5350462608";
      flake = false;
    };
    # We don't actually need this. Removing this might make caching worse?
    flat = {
      url =
        "github:Quid2/flat/ee59880f47ab835dbd73bea0847dab7869fc20d8";
      flake = false;
    };
    goblins = {
      url =
        "github:input-output-hk/goblins/cde90a2b27f79187ca8310b6549331e59595e7ba";
      flake = false;
    };
    hedgehog-extras = {
      url = "github:input-output-hk/hedgehog-extras/967d79533c21e33387d0227a5f6cc185203fe658";
      flake = false;
    };
    hw-aeson = {
      url = "github:haskell-works/hw-aeson/d99d2f3e39a287607418ae605b132a3deb2b753f";
      flake = false;
    };
    hydra-poc = {
      url = "github:input-output-hk/hydra-poc/68024d5655e032f0d75cc00fb5bffb9578ae3a82";
      flake = false;
    };
    iohk-monitoring-framework = {
      url =
        "github:input-output-hk/iohk-monitoring-framework/066f7002aac5a0efc20e49643fea45454f226caa";
      flake = false;
    };
    io-sim = {
      url =
        "github:input-output-hk/io-sim/57e888b1894829056cb00b7b5785fdf6a74c3271";
      flake = false;
    };
    optparse-applicative = {
      url =
        "github:input-output-hk/optparse-applicative/7497a29cb998721a9068d5725d49461f2bba0e7a";
      flake = false;
    };
    ouroboros-network = {
      url =
        "github:input-output-hk/ouroboros-network/a65c29b6a85e90d430c7f58d362b7eb097fd4949";
      flake = false;
    };
    plutus = {
      url =
        "github:input-output-hk/plutus/f680ac6979e069fcc013e4389ee607ff5fa6672f";
      flake = false;
    };
    plutus-apps = {
      url =
        "github:input-output-hk/plutus-apps/c2b310968d0915e2af0ea4680186b41ad88ffbe9";
      flake = false;
    };
    typed-protocols = {
      url =
        "github:input-output-hk/typed-protocols/181601bc3d9e9d21a671ce01e0b481348b3ca104";
      flake = false;
    };
    Win32-network = {
      url =
        "github:input-output-hk/Win32-network/3825d3abf75f83f406c1f7161883c438dac7277d";
      flake = false;
    };
  };

  outputs = { self, haskell-nix, iohk-nix, nixpkgs, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        nixpkgsFor = import nixpkgs {
          inherit system overlays;
          inherit (haskell-nix) config;
        };

        overlays = [
          haskell-nix.overlay

          # needed for cardano-api which uses a patched libsodium  
          (import "${iohk-nix}/overlays/crypto")

          (final: prev: {
            hydraDemoProject = final.haskell-nix.project' {
              compiler-nix-name = "ghc8107";

              src = final.haskell-nix.haskellLib.cleanGit {
                name = "hydra-demo";
                src = ./.;
              };

              shell = {
                nativeBuildInputs = with final; [
                  nixpkgs-fmt
                  git
                ];

                tools = {
                  cabal = { };
                  cabal-fmt = { };
                  fourmolu = "0.4.0.0";
                  hlint = { };
                };

                cabalProjectLocal = ''
                  allow-newer: *:aeson, size-based:template-haskell
                  constraints: aeson >= 2, hedgehog >= 1.1
                '';

                modules = [
                ({ pkgs, ... }:
                  {
                    packages = {
                      marlowe.flags.defer-plugin-errors = true;
                      plutus-use-cases.flags.defer-plugin-errors = true;
                      plutus-ledger.flags.defer-plugin-errors = true;
                      plutus-script-utils.flags.defer-plugin-errors = true;
                      plutus-contract.flags.defer-plugin-errors = true;
                      cardano-crypto-praos.components.library.pkgconfig = pkgs.lib.mkForce [ [ pkgs.libsodium-vrf ] ];
                      cardano-crypto-class.components.library.pkgconfig = pkgs.lib.mkForce [ [ pkgs.libsodium-vrf ] ];
                      cardano-wallet-core.components.library.build-tools = [
                        pkgs.buildPackages.buildPackages.gitMinimal
                      ];
                      cardano-config.components.library.build-tools = [
                        pkgs.buildPackages.buildPackages.gitMinimal
                      ];
                    };
                  }
                )
              ];

              extraSources = [
                  {
                    src = inputs.cardano-addresses;
                    subdirs = [ "core" "command-line" ];
                  }
                  {
                    src = inputs.cardano-base;
                    subdirs = [
                      "base-deriving-via"
                      "binary"
                      "binary/test"
                      "cardano-crypto-class"
                      "cardano-crypto-praos"
                      "cardano-crypto-tests"
                      "measures"
                      "orphans-deriving-via"
                      "slotting"
                      "strict-containers"
                    ];
                  }
                  {
                    src = inputs.cardano-crypto;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.cardano-ledger;
                    subdirs = [
                      "eras/alonzo/impl"
                      "eras/babbage/impl"
                      "eras/byron/chain/executable-spec"
                      "eras/byron/crypto"
                      "eras/byron/crypto/test"
                      "eras/byron/ledger/executable-spec"
                      "eras/byron/ledger/impl"
                      "eras/byron/ledger/impl/test"
                      "eras/shelley/impl"
                      "eras/shelley/test-suite"
                      "eras/shelley-ma/impl"
                      "libs/cardano-data"
                      "libs/cardano-ledger-core"
                      "libs/cardano-ledger-pretty"
                      "libs/cardano-protocol-tpraos"
                      "libs/vector-map"
                      "libs/non-integral"
                      "libs/set-algebra"
                      "libs/small-steps"
                      "libs/small-steps-test"
                    ];
                  }
                  {
                    src = inputs.cardano-node;
                    subdirs = [
                      "cardano-api"
                      "cardano-cli"
                      "cardano-git-rev"
                      "cardano-node"
                      "cardano-submit-api"
                      "cardano-testnet"
                      "trace-dispatcher"
                      "trace-forward"
                      "trace-resources"
                    ];
                  }
                  {
                    src = inputs.cardano-config;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.cardano-prelude;
                    subdirs = [ "cardano-prelude" "cardano-prelude-test" ];
                  }
                  {
                    src = inputs.cardano-wallet;
                    subdirs = [
                      "lib/cli"
                      "lib/core"
                      "lib/core-integration"
                      "lib/dbvar"
                      "lib/launcher"
                      "lib/numeric"
                      "lib/shelley"
                      "lib/strict-non-empty-containers"
                      "lib/test-utils"
                      "lib/text-class"
                    ];
                  }
                  {
                    src = inputs.ekg-forward;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.ekg-json;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.flat;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.goblins;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.hedgehog-extras;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.hw-aeson;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.hydra-poc;
                    subdirs = [
                      "hydra-cardano-api"
                      "hydra-cluster"
                      "hydra-node"
                      "hydra-plutus"
                      "hydra-prelude"
                      "hydra-test-utils"
                      "hydra-tui"
                      "plutus-cbor"
                      "plutus-merkle-tree"
                    ];
                  }
                  {
                    src = inputs.iohk-monitoring-framework;
                    subdirs = [
                      "contra-tracer"
                      "iohk-monitoring"
                      "tracer-transformers"
                      "plugins/backend-ekg"
                      "plugins/backend-aggregation"
                      "plugins/backend-monitoring"
                      "plugins/backend-trace-forwarder"
                    ];
                  }
                  {
                    src = inputs.io-sim;
                    subdirs = [
                      "io-classes"
                      "io-sim"
                      "strict-stm"
                    ];
                  }
                  {
                    src = inputs.optparse-applicative;
                    subdirs = [ "." ];
                  }
                  {
                    src = inputs.ouroboros-network;
                    subdirs = [
                      "monoidal-synchronisation"
                      "network-mux"
                      "ntp-client"
                      "ouroboros-consensus"
                      "ouroboros-consensus-byron"
                      "ouroboros-consensus-cardano"
                      "ouroboros-consensus-protocol"
                      "ouroboros-consensus-shelley"
                      "ouroboros-network"
                      "ouroboros-network-framework"
                      "ouroboros-network-testing"
                    ];
                  }
                  {
                    src = inputs.plutus;
                    subdirs = [
                      "plutus-core"
                      "plutus-ledger-api"
                      "plutus-tx"
                      "plutus-tx-plugin"
                      "prettyprinter-configurable"
                      "stubs/plutus-ghc-stub"
                      "word-array"
                    ];
                  }
                  {
                    src = inputs.plutus-apps;
                    subdirs = [
                      "doc"
                      "freer-extras"
                      "playground-common"
                      "plutus-chain-index"
                      "plutus-chain-index-core"
                      "plutus-contract"
                      "plutus-contract-certification"
                      "plutus-ledger"
                      "plutus-ledger-constraints"
                      "plutus-pab"
                      "plutus-playground-server"
                      "plutus-script-utils"
                      "plutus-use-cases"
                      "quickcheck-dynamic"
                      "web-ghc"
                    ];
                  }
                  {
                    src = inputs.typed-protocols;
                    subdirs = [
                      "typed-protocols"
                      "typed-protocols-cborg"
                      "typed-protocols-examples"
                    ];
                  }
                  {
                    src = inputs.Win32-network;
                    subdirs = [ "." ];
                  }
                ];

                additional = ps: [
                  ps.hydra-test-utils
                ];
              };
            };
          })
        ];

        flake = nixpkgsFor.hydraDemoProject.flake { };
        exe-component-name = "hydra-demo:exe:hydra-rps-game";

      in
      flake // {
        defaultPackage = flake.packages.${exe-component-name};
        defaultApp = flake.apps.${exe-component-name};
        check = nixpkgsFor.runCommand "combined-test"
          {
            nativeBuildInputs = builtins.attrValues flake.checks;
          } "touch $out";
      });
}
