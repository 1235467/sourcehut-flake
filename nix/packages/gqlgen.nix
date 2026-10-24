{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:

buildGoModule rec {
  pname = "gqlgen";
  version = "0.17.64";

  src = fetchFromGitHub {
    owner = "99designs";
    repo = "gqlgen";
    tag = "v${version}";
    hash = "sha256-JzXjUOhj49rp+aALfP48mRkySObd7z5qaHH6Na649+4=";
  };

  vendorHash = "sha256-2lc79X//SwQ2lxcbdUVgmJ4iq9SnitfXsBXAq38/wn4=";

  # golang.org/x/tools v0.24.0 cannot load packages built with modern Go
  # toolchains, bump it together with its transitive dependencies.
  postPatch = ''
    go mod edit \
      -require=golang.org/x/tools@v0.49.0 \
      -require=golang.org/x/mod@v0.39.0 \
      -require=golang.org/x/net@v0.58.0 \
      -require=golang.org/x/sync@v0.22.0 \
      -require=golang.org/x/sys@v0.47.0 \
      -require=golang.org/x/text@v0.41.0 \
      -require=golang.org/x/telemetry@v0.0.0-20260811182544-a038080d80e5
  '';

  # Only runs while building the fixed-output goModules derivation, where
  # network access is available.
  modBuildPhase = ''
    export GIT_SSL_CAINFO=$NIX_SSL_CERT_FILE
    export GOFLAGS="-trimpath"
    go mod download all
    go mod vendor
  '';

  subPackages = [ "." ];

  doCheck = false;

  meta = {
    description = "Go generate based GraphQL server library";
    homepage = "https://github.com/99designs/gqlgen";
    license = lib.licenses.mit;
    mainProgram = "gqlgen";
  };
}
