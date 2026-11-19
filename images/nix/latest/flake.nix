{
  description = "builds.sr.ht nix build image guest environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # gVisor (runsc) cannot create mount/pid/user namespaces, which
      # CppNix's builder requires even with sandbox=false. Lix's
      # non-sandbox builder path avoids namespaces entirely; the local
      # patch additionally tolerates the capability/pid syscalls runsc
      # cannot emulate (ambient caps, capset, ppid check, SO_PEERGROUPS).
      lixGvisor = pkgs.lix.overrideAttrs (o: {
        patches = (o.patches or [ ]) ++ [ ./lix-gvisor.patch ];
      });
    in
    {
      packages.${system}.guestEnv = pkgs.buildEnv {
        name = "guest-env";
        paths = [
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnupg
          pkgs.gnused
          pkgs.mercurial
          pkgs.curl
          pkgs.openssh
          pkgs.sudo
          pkgs.niks3
          lixGvisor
        ];
      };
    };
}
