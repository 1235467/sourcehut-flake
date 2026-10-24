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
  bcrypt,
  dataloaden,
  dnspython,
  gqlgen,
  httpx,
  prometheus-client,
  pydantic,
  qrcode,
  redis,
  srht,
  zxcvbn,
}:

let
  version = "0.88.9";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "meta.sr.ht";
    rev = version;
    hash = "sha256-mXojiaZz3IfGM6fQ9i24aytVNqQD/oFln3zdjOgIqjI=";
  };

  python = buildPythonPackage {
    pname = "metasrht";
    inherit version src;
    pyproject = true;

    postPatch = ''
      # The GraphQL client is generated from the API schema at build time.
      rm -f metasrht/graphql/*.py
    '';

    build-system = [
      setuptools
      setuptools-scm
    ];

    dependencies = [
      srht
      bcrypt
      dnspython
      httpx
      prometheus-client
      pydantic
      qrcode
      redis
      zxcvbn
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

    pythonImportsCheck = [ "metasrht" ];

    meta = {
      description = "meta.sr.ht website";
      homepage = "https://git.sr.ht/~sircmpwn/meta.sr.ht";
      license = lib.licenses.agpl3Only;
    };
  };

  go = buildGoModule {
    pname = "metasrht-go";
    inherit version src;
    vendorHash = "sha256-3T5Y9bQ3GCt4ZNc2vp39HirWMl0Sx7Lp3I9FJW4Y5Qo=";

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
      go build -ldflags "$ldflags" -o meta.sr.ht-api ./cmd/api
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 meta.sr.ht-api $out/bin/meta.sr.ht-api
      runHook postInstall
    '';

    doCheck = false;

    meta = python.meta;
  };
in
buildEnv {
  name = "metasrht-${version}";

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
