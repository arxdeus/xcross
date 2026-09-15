# asn1 2.8.x, pinned.
#
# PyIMG4 (a pymobiledevice3 dependency, via ipsw-parser) only supports
# `asn1<3` — see https://github.com/m1stadev/PyIMG4/issues/59.  nixpkgs ships
# asn1 3.x and consequently marks pyimg4 broken.  pymobiledevice3 itself only
# uses the stable Encoder/Decoder API (`restore/tss.py`), which works with 2.x,
# so this package set pins the whole environment back to 2.8.0.
#
# 2.8.0 predates pyproject.toml, hence the plain setuptools build.
{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  pytestCheckHook,
  setuptools,
}:

buildPythonPackage rec {
  pname = "asn1";
  version = "2.8.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "andrivet";
    repo = "python-asn1";
    tag = "v${version}";
    hash = "sha256-DLKfdQzYLhfaIEPPymTzRqj3+L/fsm5Jh8kqud/ezfw=";
  };

  build-system = [ setuptools ];

  # Only needed to backport `enum` to Python < 3.4.
  pythonRemoveDeps = [ "enum-compat" ];

  nativeCheckInputs = [ pytestCheckHook ];

  enabledTestPaths = [ "tests/test_asn1.py" ];

  pythonImportsCheck = [ "asn1" ];

  meta = {
    changelog = "https://github.com/andrivet/python-asn1/blob/${src.tag}/CHANGELOG.rst";
    description = "Python ASN.1 encoder and decoder";
    homepage = "https://github.com/andrivet/python-asn1";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ fab ];
  };
}