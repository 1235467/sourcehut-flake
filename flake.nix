{
  description = "Latest SourceHut (git.sr.ht + meta.sr.ht) packages and NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      scope = pkgs: import ./nix/packages { inherit pkgs; };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          p = scope pkgs;
        in
        p // { default = p.gitsrht; }
      );

      overlays.default = final: _prev: {
        sourcehut = scope final;
      };

      nixosModules.default = ./nix/modules/sourcehut.nix;
      nixosModules.sourcehut = ./nix/modules/sourcehut.nix;
    };
}
