{ lib
, buildEnv
, buildGoModule
, buildPythonPackage
, fetchFromSourcehut
, minify
, sassc
, setuptools
, setuptools-scm
, ansi2html
, ariadne-codegen
, bleach
, dataloaden
, gqlgen
, httpx
, lxml
, markdown
, markupsafe
, pydantic
, pyyaml
, redis
, metasrht
, srht
,
}:

let
  version = "0.105.6";

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "builds.sr.ht";
    rev = version;
    hash = "sha256-NL19GAte1JyVBj2GzFHQnKNi/TTyDJujHFJzdekq+HE=";
  };

  python = buildPythonPackage {
    pname = "buildsrht";
    inherit version src;
    pyproject = true;

    postPatch = ''
      # The GraphQL clients are generated from the API schemas at build time.
      rm -f buildsrht/graphql/*.py buildsrht/meta/*.py
      # The meta.sr.ht client is generated against metasrht's packaged schema;
      # upstream substitutes its asset dir for @ASSETS@ in ariadne/meta.toml.
      sed -e 's:@ASSETS@:${metasrht}/share/sourcehut:g' \
        ariadne/meta.toml.in > ariadne/meta.toml
    '';

    build-system = [
      setuptools
      setuptools-scm
    ];

    dependencies = [
      srht
      ansi2html
      bleach
      httpx
      lxml
      markdown
      markupsafe
      pydantic
      pyyaml
      redis
    ];

    nativeBuildInputs = [
      ariadne-codegen
      sassc
      minify
    ];

    env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

    preBuild = ''
      ariadne-codegen
      ariadne-codegen --config ariadne/meta.toml
    '';

    postBuild = ''
      make SASSC_INCLUDE=-I${srht}/share/sourcehut/scss all-share
    '';

    postInstall = ''
      make PREFIX=$out SASSC_INCLUDE=-I${srht}/share/sourcehut/scss install-share
    '';

    # Only the bare package: the generated GraphQL clients import srht.crypto,
    # which reads its keys from config.ini at import time; that is covered in
    # checkPhase below, after a throwaway config.ini has been written.
    pythonImportsCheck = [ "buildsrht" ];
    # Import the generated GraphQL clients too: srht.crypto reads its keys
    # at import time (hence the throwaway config.ini) and the clients pull
    # in runtime dependencies which nothing else would validate at build
    # time.
    checkPhase = ''
      runHook preCheck
      printf '[sr.ht]\nnetwork-key=%s\n[webhooks]\nprivate-key=%s\n[meta.sr.ht]\norigin=https://meta.example.com\n[builds.sr.ht]\norigin=https://builds.example.com\n' \
        "$(python -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')" \
        "$(python -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')" > config.ini
      python -c 'import buildsrht, buildsrht.graphql, buildsrht.meta'
      runHook postCheck
    '';

    meta = {
      description = "builds.sr.ht website";
      homepage = "https://git.sr.ht/~sircmpwn/builds.sr.ht";
      license = lib.licenses.agpl3Only;
    };
  };

  go = buildGoModule {
    pname = "buildsrht-go";
    inherit version src;
    vendorHash = "sha256-zy2N+ulMcYP9DjFoSNiBATMz3uUc4kptpHkS60aQU1g=";

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
      go build -ldflags "$ldflags" -o builds.sr.ht-api ./cmd/api
      go build -ldflags "$ldflags" -o builds.sr.ht-shell ./cmd/shell
      go build -ldflags "$ldflags" -o builds.sr.ht-worker ./cmd/worker
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      for b in builds.sr.ht-api builds.sr.ht-shell builds.sr.ht-worker; do
        install -Dm755 "$b" "$out/bin/$b"
      done
      runHook postInstall
    '';

    doCheck = false;

    meta = python.meta;
  };
in
buildEnv {
  name = "buildsrht-${version}";

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
