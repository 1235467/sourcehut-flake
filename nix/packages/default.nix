{ pkgs }:

let
  py = pkgs.python3Packages;

  srht = py.callPackage ./srht.nix { };
  scmsrht = py.callPackage ./scmsrht.nix { inherit srht; };
  ariadne-codegen = py.callPackage ./ariadne-codegen.nix { };
  gqlgen = pkgs.callPackage ./gqlgen.nix { };
  dataloaden = pkgs.callPackage ./dataloaden.nix { };
  gitsrht = py.callPackage ./gitsrht.nix {
    inherit
      srht
      scmsrht
      ariadne-codegen
      dataloaden
      gqlgen
      ;
  };
  metasrht = py.callPackage ./metasrht.nix {
    inherit
      srht
      ariadne-codegen
      dataloaden
      gqlgen
      ;
  };
  sourcehut-ssh = pkgs.callPackage ./sourcehut-ssh.nix { };
  sourcehut-migrate = pkgs.callPackage ./sourcehut-migrate.nix { };
in
{
  inherit
    srht
    scmsrht
    gitsrht
    metasrht
    sourcehut-ssh
    sourcehut-migrate
    ariadne-codegen
    gqlgen
    dataloaden
    ;
}
