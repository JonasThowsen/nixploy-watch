{
  description = "Ask Jev whether nixploy-managed containers are healthy and email when they are not";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" ];
      pkgsFor = system: import nixpkgs { inherit system; };
      ocamlPackagesFor = pkgs: pkgs.ocaml-ng.ocamlPackages_5_2;
      # Podman is not bundled: the watcher must use the host's Podman so it
      # reads the same container storage nixploy deployed into.
      runtimeTools = pkgs: [
        pkgs.curl
        pkgs.sops
      ];
    in
    {
      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = ocamlPackagesFor pkgs;
          nixployWatch = ocamlPackages.buildDunePackage {
            pname = "nixploy-watch";
            version = "0.1.0";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./dune-project
                ./nixploy-watch.opam
                ./lib
                ./bin
                ./test
              ];
            };
            duneVersion = "3";
            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = with ocamlPackages; [
              async
              core
              core_unix
              ppx_jane
              yojson
            ];
            doCheck = true;
            postFixup = ''
              wrapProgram "$out/bin/nixploy-watch" \
                --prefix PATH : ${lib.makeBinPath (runtimeTools pkgs)}
            '';
            meta.mainProgram = "nixploy-watch";
          };
        in
        {
          nixploy-watch = nixployWatch;
          default = nixployWatch;
        }
      );

      nixosModules.default = import ./nix/module.nix { inherit self; };

      checks = forAllSystems (system: {
        nixploy-watch = self.packages.${system}.nixploy-watch;
        vm = import ./nix/vm-test.nix {
          pkgs = pkgsFor system;
          nixployWatchModule = self.nixosModules.default;
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = ocamlPackagesFor pkgs;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.nixploy-watch ];
            packages = runtimeTools pkgs ++ [
              pkgs.podman
              ocamlPackages.ocaml-lsp
              ocamlPackages.ocamlformat
            ];
          };
        }
      );
    };
}
