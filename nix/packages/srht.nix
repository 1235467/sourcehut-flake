{
  lib,
  fetchFromSourcehut,
  fetchFromGitHub,
  buildPythonPackage,
  setuptools,
  setuptools-scm,

  beautifulsoup4,
  celery,
  cryptography,
  flask,
  humanize,
  markdown,
  mistletoe,
  nh3,
  prometheus-client,
  psycopg2,
  pygments,
  redis,
  requests,
  sqlalchemy,
  sqlalchemy-utils,
}:

let
  bootstrap = fetchFromGitHub {
    owner = "twbs";
    repo = "bootstrap";
    tag = "v4.1.1";
    hash = "sha256-1Dj5itr12Zdc+9LZ95Si6nwqIjvNa8HW47tBj0rjhz4=";
  };
in
buildPythonPackage rec {
  pname = "srht";
  version = "0.84.10";
  pyproject = true;

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "core.sr.ht";
    rev = version;
    hash = "sha256-alDjRVT95o95hYRgYd8WAAL8DfuoM7xTyAQUTN43xYE=";
  };

  postPatch = ''
    rm -rf scss/bootstrap
    mkdir -p scss/bootstrap
    cp ${bootstrap}/LICENSE scss/bootstrap/
    cp -r ${bootstrap}/scss scss/bootstrap/
  '';

  build-system = [
    setuptools
    setuptools-scm
  ];

  dependencies = [
    beautifulsoup4
    celery
    cryptography
    flask
    humanize
    markdown
    mistletoe
    nh3
    prometheus-client
    psycopg2
    pygments
    redis
    requests
    sqlalchemy
    sqlalchemy-utils
  ];

  env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

  postInstall = ''
    make PREFIX=$out install
  '';

  pythonImportsCheck = [ "srht" ];

  meta = {
    description = "sr.ht core modules and shared assets";
    homepage = "https://git.sr.ht/~sircmpwn/core.sr.ht";
    license = lib.licenses.bsd3;
  };
}
