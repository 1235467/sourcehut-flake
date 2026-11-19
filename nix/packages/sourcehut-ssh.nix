{ lib
, fetchFromSourcehut
, buildGoModule
,
}:

buildGoModule rec {
  pname = "sourcehut-ssh";
  version = "0.6.1";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "sourcehut-ssh";
    rev = version;
    hash = "sha256-1pU3AxyqU4eJE6LCPtMao+aKx2ncBPDUZpP9SYxGZBA=";
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
