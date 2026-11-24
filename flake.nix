{
  description = "Development environment for relay";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
            "**/.render/**"
            "**/build/**"
            "**/.artifacts/**"
            "**/node_modules/**"
            "fixtures/negative/**"
            "test/fixtures/tls/**"
            "scripts/conformance/pnpm-lock.yaml"
          ];
          programs.gleam.enable = true;
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
          programs.ruff.format = true;
          programs.shfmt.enable = true;
          settings.formatter.shfmt.options = [
            "-i"
            "2"
          ];
        };
      in
      {
        # Realized only when the schema comparison invokes this app.
        apps.oracle-mcp-schema = {
          type = "app";
          program = "${pkgs.writeShellScript "oracle-mcp-schema" ''
            printf '%s\n' ${
              pkgs.fetchurl {
                name = "mcp-2026-07-28-schema.json";
                url = "https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json";
                sha256 = "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203";
              }
            }
          ''}";
        };
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            git
            lefthook
            gleam
            nodejs_22
            pnpm
            beam29Packages.erlang
            beam29Packages.rebar3
            ruff
            shfmt
            coreutils
            (python3.withPackages (ps: [ ps.jsonschema ]))
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
