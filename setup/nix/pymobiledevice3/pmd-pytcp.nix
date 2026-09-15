{
  lib,
  buildPythonPackage,
  fetchPypi,
  pmd-net-addr,
  pmd-net-proto,
  setuptools,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "pmd-pytcp";
  version = "0.3.7";
  pyproject = true;

  src = fetchPypi {
    pname = "pmd_pytcp";
    inherit version;
    hash = "sha256-iGHAkfP65W+J0QE24svPyxCOr1KdCaubmJSikQlIsTg=";
  };

  build-system = [ setuptools ];

  dependencies = [
    pmd-net-addr
    pmd-net-proto
    typing-extensions
  ];

  pythonImportsCheck = [ "pmd_pytcp" ];

  meta = {
    description = "Pure-Python userspace TCP/IP stack (PyTCP fork)";
    homepage = "https://github.com/doronz88/pmd-pytcp";
    license = lib.licenses.gpl3Plus;
    mainProgram = "pytcpd";
  };
}
