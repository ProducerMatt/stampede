{
  description = "Stampede dev environment and pre-push checks";
  # NOTE: enter the environment with `nix develop .#`

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.flake-utils.url = "github:nix-resources/flake-utils/nix-resources-stable";

  inputs.git-hooks.url = "github:cachix/git-hooks.nix";
  inputs.git-hooks.inputs.nixpkgs.follows = "nixpkgs";

  outputs = {
    # self,
    nixpkgs,
    flake-utils,
    git-hooks,
    ...
  }:
    flake-utils.lib.eachDefaultSystem
    (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};

        ########################
        # Erlang/Elixir versions
        erl = with pkgs; beam.packages.erlang_26;
        ex = erl.elixir_1_16;

        ########################
        # Git pre-push checks
        pc-hooks = git-hooks.lib.${system}.run {
          # only run on push and directly calling `pre-commit` in the shell
          default_stages = ["manual" "push" "pre-merge-commit"];
          src = ./.;
          hooks = let
            enable_on_commit = {
              enable = true;
              stages = ["manual" "push" "pre-merge-commit" "pre-commit"];
            };
          in {
            check-merge-conflicts.enable = true;
            check-vcs-permalinks.enable = true;
            editorconfig-checker = enable_on_commit;
            # TODO: tagref

            alejandra = enable_on_commit;
            flake-checker.enable = true;

            # NOTE: disable to reduce deps
            actionlint = enable_on_commit;
            yamlfmt = enable_on_commit;
            convco = {
              enable = true;
              stages = ["commit-msg"];
            };
            deadnix.enable = true;

            dialyzer = {
              enable = true;
              package = ex;
            };
            custom-mix-test = {
              enable = true;
              name = "mix-test";
              entry = "${ex}/bin/mix test";
              files = "\\.exs?$";
              types = ["text"];
              pass_filenames = false;
              require_serial = true;
            };
            custom-mix-format = {
              enable = true;
              name = "mix-format";
              entry = "${ex}/bin/mix format --check-formatted";
              files = "\\.exs?$";
              types = ["text"];
              pass_filenames = false;
              require_serial = true;
              stages = ["manual" "push" "pre-merge-commit" "pre-commit"];
            };
          };
        };
      in {
        #####################
        # FLAKE OUTPUTS
        checks.default = pc-hooks;
        devShells.default = let
          #####################
          # DEV SHELL WITH PRE-PUSH HOOKS
          inputs =
            [
              ex
              (erl.elixir-ls.override {elixir = ex;})

              pkgs.libyaml
              pkgs.libyaml.dev
            ]
            ++ pc-hooks.enabledPackages;

          # define shell startup command
          sh-hook = ''
            # this allows mix to work on the local directory
            mkdir -p .nix-mix
            mkdir -p .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$PATH
            export PATH=$HEX_HOME/bin:$PATH
            export LANG=en_US.UTF-8
            export ERL_AFLAGS="-kernel shell_history enabled"

            ${pc-hooks.shellHook}
          '';
        in
          pkgs.mkShell {
            buildInputs = inputs;
            shellHook = sh-hook;
          };
      }
    );
}
