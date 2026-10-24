{
  lib,
  buildEnv,
  buildGoModule,
  buildPythonPackage,
  fetchFromSourcehut,
  minify,
  sassc,
  setuptools,
  setuptools-scm,

  ariadne-codegen,
  dataloaden,
  gqlgen,
  httpx,
  pydantic,
  pygit2,
  scmsrht,
  srht,
}:

let
  version = "0.102.8";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "git.sr.ht";
    rev = version;
    hash = "sha256-CNjthQLdqXHbp7oluDnX1zeOyIX16O3QiNsXw8ibLVc=";
  };

  python = buildPythonPackage {
    pname = "gitsrht";
    inherit version src;
    pyproject = true;

    postPatch = ''
      # The GraphQL client is generated from the API schema at build time.
      rm -f gitsrht/graphql/*.py
    '';

    build-system = [
      setuptools
      setuptools-scm
    ];

    dependencies = [
      srht
      scmsrht
      pygit2
      httpx
      pydantic
    ];

    nativeBuildInputs = [
      ariadne-codegen
      sassc
      minify
    ];

    env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

    preBuild = ''
      ariadne-codegen
    '';

    postBuild = ''
      make SASSC_INCLUDE=-I${srht}/share/sourcehut/scss all-share
    '';

    postInstall = ''
      make PREFIX=$out SASSC_INCLUDE=-I${srht}/share/sourcehut/scss install-share
    '';

    pythonImportsCheck = [ "gitsrht" ];

    meta = {
      description = "git.sr.ht website";
      homepage = "https://git.sr.ht/~sircmpwn/git.sr.ht";
      license = lib.licenses.agpl3Only;
    };
  };

  go = buildGoModule {
    pname = "gitsrht-go";
    inherit version src;
    vendorHash = "sha256-/JGLcjpGqRT/w7/318kNisNWteRO09OlS2TzPV0n0LA=";

    nativeBuildInputs = [
      dataloaden
      gqlgen
    ];

    ldflags = [
      "-X git.sr.ht/~sircmpwn/core-go/server.BuildVersion=${version}"
    ];

    postPatch = ''
      substituteInPlace api/graph/generate.go \
        --replace-fail "go run github.com/99designs/gqlgen" "${gqlgen}/bin/gqlgen"
      substituteInPlace api/loaders/gen \
        --replace-fail "go run github.com/vektah/dataloaden" "${dataloaden}/bin/dataloaden"
      printf '\nskip_mod_tidy: true\n' >> api/gqlgen.yml
    '';

    # Runs only while building the fixed-output goModules derivation, which
    # has network access; the generated code is required for `go mod vendor`
    # to resolve all imported packages.
    modBuildPhase = ''
      export GIT_SSL_CAINFO=$NIX_SSL_CERT_FILE
      export GOFLAGS="-trimpath"
      (cd api && go generate ./loaders && go generate ./graph)
      go mod vendor
    '';

    postConfigure = ''
      cd api
      go generate ./loaders
      go generate ./graph
      cd ..
    '';

    buildPhase = ''
      runHook preBuild
      go build -ldflags "$ldflags" -o git.sr.ht-api ./cmd/api
      go build -ldflags "$ldflags" -o git.sr.ht-shell ./cmd/shell
      go build -ldflags "$ldflags" -o git.sr.ht-http-clone ./cmd/http-clone
      go build -ldflags "$ldflags" -o git.sr.ht-update-hook ./cmd/update-hook
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      for b in git.sr.ht-api git.sr.ht-shell git.sr.ht-http-clone git.sr.ht-update-hook; do
        install -Dm755 "$b" "$out/bin/$b"
      done
      runHook postInstall
    '';

    doCheck = false;

    meta = python.meta;
  };
in
buildEnv {
  name = "gitsrht-${version}";

  paths = [
    python
    go
  ];

  pathsToLink = [
    "/bin"
    "/share"
  ];

  passthru = {
    inherit python;
  };

  meta = python.meta;
}
