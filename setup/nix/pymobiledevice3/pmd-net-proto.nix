{
  lib,
  buildPythonPackage,
  fetchPypi,
  pmd-net-addr,
  setuptools,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "pmd-net-proto";
  version = "0.0.3";
  pyproject = true;

  src = fetchPypi {
    pname = "pmd_net_proto";
    inherit version;
    hash = "sha256-4j19aM0TOZ/yvwYT+XVuIh6tb9VAEM+FGGwqtlBjHNc=";
  };

  build-system = [ setuptools ];

  dependencies = [
    pmd-net-addr
    typing-extensions
  ];

  pythonImportsCheck = [ "pmd_net_proto" ];

  meta = {
    description = "Ethernet-through-TCP/UDP packet parsing for the PyTCP stack";
    homepage = "https://github.com/ccie18643/PyTCP";
    license = lib.licenses.gpl3Plus;
  };
}
