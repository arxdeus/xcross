{
  lib,
  bpylist2,
  buildPythonPackage,
  click,
  construct,
  cryptography,
  fetchPypi,
  packaging,
  setuptools,
}:

buildPythonPackage rec {
  pname = "pyiosbackup";
  version = "0.2.4";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-ELTSoRyb7ck6VGfK063b4YvC3ENBVpIOciMibtTQvrc=";
  };

  build-system = [ setuptools ];

  dependencies = [
    bpylist2
    click
    construct
    cryptography
    packaging
  ];

  pythonImportsCheck = [ "pyiosbackup" ];

  meta = {
    description = "Parse and unpack iOS backups";
    homepage = "https://github.com/doronz88/pyiosbackup";
    license = lib.licenses.gpl3Plus;
  };
}
