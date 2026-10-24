{
  lib,
  fetchFromSourcehut,
  buildGoModule,
}:

buildGoModule rec {
  pname = "sourcehut-ssh";
  version = "0.6.0";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "sourcehut-ssh";
    rev = version;
    hash = "sha256-atkMJ/g74RNGSeiv+aj2tO5snr4Lj5RgdfaD0Kgb0uw=";
  };

  vendorHash = "sha256-pSYx7920kBdjIIFGTXWgPEVpF29pTN4zbEwxoQZ6irI=";

  subPackages = [ "cmd/sourcehut-ssh" ];

  doCheck = false;

  meta = {
    description = "SourceHut unified SSH dispatcher";
    homepage = "https://git.sr.ht/~sircmpwn/sourcehut-ssh";
    license = lib.licenses.agpl3Only;
    mainProgram = "sourcehut-ssh";
  };
}
