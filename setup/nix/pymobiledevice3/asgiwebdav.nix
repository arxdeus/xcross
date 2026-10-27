{
  lib,
  aiofiles,
  asgimiddlewarestaticfile,
  asgiref,
  buildPythonPackage,
  chardet,
  click,
  dataclass-wizard,
  fetchPypi,
  python-dotenv,
  setuptools,
  xmltodict,
}:

buildPythonPackage rec {
  pname = "asgiwebdav";
  version = "2.0.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-S8sM2wVmHbefoa9zGE/eTeb4H/Lstshxa1uhgu99RGA=";
  };

  build-system = [ setuptools ];

  dependencies = [
    aiofiles
    asgimiddlewarestaticfile
    asgiref
    chardet
    click
    dataclass-wizard
    python-dotenv
    xmltodict
  ];

  pythonImportsCheck = [ "asgi_webdav" ];

  meta = {
    description = "ASGI WebDAV server";
    homepage = "https://github.com/rexzhang/asgi-webdav";
    license = lib.licenses.mit;
  };
}
