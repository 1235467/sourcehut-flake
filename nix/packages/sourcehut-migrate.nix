{
  lib,
  fetchFromSourcehut,
  buildGoModule,
}:

buildGoModule rec {
  pname = "sourcehut-migrate";
  version = "0.3.1";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "sourcehut-migrate";
    rev = "v${version}";
    hash = "sha256-XoT9IZFzwz+7D0wkz/J44rArUoZeYIccAMe9Eb1LfIg=";
  };

  vendorHash = "sha256-yLz0GoljZ89PqmQ0XLbV0C+vrpBZUUFTqXDDg2CirMY=";

  subPackages = [ "cmd/sourcehut-migrate" ];

  doCheck = false;

  meta = {
    description = "SourceHut unified database migration tool";
    homepage = "https://git.sr.ht/~sircmpwn/sourcehut-migrate";
    license = lib.licenses.agpl3Only;
    mainProgram = "sourcehut-migrate";
  };
}
