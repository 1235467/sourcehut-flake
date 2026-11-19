{
  description = "builds.sr.ht nix build image guest environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.guestEnv = pkgs.buildEnv {
        name = "guest-env";
        paths = with pkgs; [
          bashInteractive
          coreutils
          findutils
          gawk
          git
          gnugrep
          gnupg
          gnused
          mercurial
          curl
          openssh
          sudo
          niks3
        ];
      };
    };
}
