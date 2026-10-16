{
  lib,
  aiofiles,
  asgiref,
  buildPythonPackage,
  fetchPypi,
  setuptools,
}:

buildPythonPackage rec {
  pname = "asgimiddlewarestaticfile";
  version = "0.7.0";
  pyproject = true;

  src = fetchPypi {
    pname = "asgimiddlewarestaticfile";
    inherit version;
    hash = "sha256-cJNas7uc3eXPltzE7tL845yc9R7DcUkCZeZz3wmd33I=";
  };

  build-system = [ setuptools ];

  dependencies = [
    aiofiles
    asgiref
  ];

  pythonImportsCheck = [ "asgi_middleware_static_file" ];

  meta = {
    description = "Static file ASGI middleware";
    homepage = "https://github.com/rexzhang/asgi-middleware-static-file";
    license = lib.licenses.mit;
  };
}
