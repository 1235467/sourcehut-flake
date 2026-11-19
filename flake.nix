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
      # Wrapper that builds the sourcehut packages with this flake's
      # locked nixpkgs instead of the consumer's — the package set is
      # sensitive to its build toolchain (see nix/modules/sourcehut.nix).
      # Importing ./nix/modules/sourcehut.nix directly still works: it
      # falls back to the revision pinned in flake.lock.
      sourcehutModule =
        { pkgs, ... }:
        {
          _module.args.sourcehutNixpkgs = nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
          imports = [ ./nix/modules/sourcehut.nix ];
        };
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

      nixosModules.sourcehut = sourcehutModule;
      nixosModules.default = sourcehutModule;
    };
}
