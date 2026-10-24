{
  lib,
  fetchFromSourcehut,
  buildPythonPackage,
  setuptools,
  setuptools-scm,
  srht,
}:

buildPythonPackage rec {
  pname = "scmsrht";
  version = "0.22.30";
  pyproject = true;

  src = fetchFromSourcehut {
    owner = "~sircmpwn";
    repo = "scm.sr.ht";
    rev = version;
    hash = "sha256-ppr6hnyC2uRfC6kA9olU/n2dgtssc9K7EizqEuV+bG8=";
  };

  build-system = [
    setuptools
    setuptools-scm
  ];

  dependencies = [ srht ];

  env.SETUPTOOLS_SCM_PRETEND_VERSION = version;

  pythonImportsCheck = [ "scmsrht" ];

  meta = {
    description = "scm.sr.ht shared code";
    homepage = "https://git.sr.ht/~sircmpwn/scm.sr.ht";
    license = lib.licenses.agpl3Only;
  };
}
