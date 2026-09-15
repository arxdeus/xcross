{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "pmd-net-addr";
  version = "0.0.3";
  pyproject = true;

  src = fetchPypi {
    pname = "pmd_net_addr";
    inherit version;
    hash = "sha256-Gw/LO3fzAHYjc2DrTPAkNIMniiZQ/UoZSYXMabHeB+U=";
  };

  build-system = [ setuptools ];

  dependencies = [ typing-extensions ];

  pythonImportsCheck = [ "pmd_net_addr" ];

  meta = {
    description = "Network address primitives from the PyTCP stack, usable standalone";
    homepage = "https://github.com/ccie18643/PyTCP";
    license = lib.licenses.gpl3Plus;
  };
}
