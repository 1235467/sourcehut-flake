{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

buildGoModule rec {
  pname = "dataloaden";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "vektah";
    repo = "dataloaden";
    tag = "v${version}";
    hash = "sha256-PPL+mG5m4Z3dIdRNBOiDHuUACGx25bLq6Ql7SciHp50=";
  };

  vendorHash = "sha256-HWwaI7+fMXwecG/Hp+yLh3WST9TwSdc92vyrxi1sZ3E=";

  subPackages = [ "." ];

  doCheck = false;

  meta = {
    description = "Go dataloader code generator";
    homepage = "https://github.com/vektah/dataloaden";
    license = lib.licenses.mit;
    mainProgram = "dataloaden";
  };
}
