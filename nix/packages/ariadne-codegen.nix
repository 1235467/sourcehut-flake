{
  lib,
  fetchurl,
  buildPythonApplication,
  click,
  graphql-core,
  httpx,
  pydantic,
  ruff,
  toml,
  hatchling,
}:

buildPythonApplication rec {
  pname = "ariadne-codegen";
  version = "0.19.0";
  pyproject = true;

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/source/a/ariadne-codegen/ariadne_codegen-${version}.tar.gz";
    hash = "sha256-UXAk4CtbuS6w0Tb+SQK1k6XKRbi6OKLGg+JGKQJJRxQ=";
  };

  build-system = [ hatchling ];

  dependencies = [
    click
    graphql-core
    httpx
    pydantic
    ruff
    toml
  ];

  # Only the ruff CLI is used, whose interface is stable across versions.
  # graphql-core 3.2.7 is a patch release; the lower bound is relaxed so the
  # package also builds against slightly older nixpkgs revisions.
  pythonRelaxDeps = [
    "ruff"
    "graphql-core"
  ];

  doCheck = false;

  meta = {
    description = "Generate fully typed GraphQL client from schema, queries and mutations";
    homepage = "https://github.com/mirumee/ariadne-codegen";
    changelog = "https://github.com/mirumee/ariadne-codegen/releases/tag/${version}";
    license = lib.licenses.bsd3;
    mainProgram = "ariadne-codegen";
  };
}
