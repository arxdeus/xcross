{
  lib,
  av,
  asgiwebdav,
  asn1,
  backports-zstd,
  bpylist2,
  buildPythonPackage,
  coloredlogs,
  construct,
  construct-typing,
  cryptography,
  daemonize,
  defusedxml,
  developer-disk-image,
  fastapi,
  fetchFromGitHub,
  glib,
  gpxpy,
  hexdump,
  hyperframe,
  httpx,
  ifaddr,
  ipsw-parser,
  ipython,
  libusb1,
  makeWrapper,
  opack2,
  packaging,
  parameter-decorators,
  pillow,
  plumbum,
  pmd-pytcp,
  prompt-toolkit,
  psutil,
  pycrashreport,
  pygments,
  pygnuutils,
  pyimg4,
  pyiosbackup,
  pykdebugparser,
  python-pcapng,
  pytest-asyncio,
  pytestCheckHook,
  pytun-pmd3,
  pyusb,
  qh3,
  questionary,
  requests,
  setuptools,
  setuptools-scm,
  srptools,
  stdenv,
  tqdm,
  typer,
  typer-injector,
  typing-extensions,
  uvicorn,
  wsproto,
  xdg-utils,
  xonsh,
}:

buildPythonPackage rec {
  pname = "pymobiledevice3";
  version = "11.12.5";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "doronz88";
    repo = "pymobiledevice3";
    tag = "v${version}";
    hash = "sha256-mlP9XUmVa6Dx7/m05cDwad9mYn8sytD9Sq50au+VI64=";
  };

  build-system = [
    setuptools
    setuptools-scm
  ];

  # Mirrors the `dependencies` list in pyproject.toml for Python 3.10+.
  # `sslpsk-pmd3` and the 3.9 typer pin are deliberately absent: we build
  # against Python 3.13.
  dependencies = [
    asgiwebdav
    asn1
    backports-zstd
    bpylist2
    coloredlogs
    construct
    construct-typing
    cryptography
    daemonize
    defusedxml
    developer-disk-image
    fastapi
    gpxpy
    hexdump
    hyperframe
    ifaddr
    ipsw-parser
    ipython
    opack2
    packaging
    parameter-decorators
    pillow
    plumbum
    pmd-pytcp
    prompt-toolkit
    psutil
    pycrashreport
    pygments
    pygnuutils
    pyimg4
    pyiosbackup
    pykdebugparser
    python-pcapng
    pytun-pmd3
    pyusb
    qh3
    questionary
    requests
    srptools
    tqdm
    typer
    typer-injector
    typing-extensions
    uvicorn
    wsproto
    xonsh
  ]
  ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [ av ];

  nativeBuildInputs = [ makeWrapper ];

  # Both are deliberately older than upstream's lower bounds but are known to
  # work, so drop the versions from the wheel metadata:
  #   * construct-typing 0.7.0 is explicitly supported through the
  #     `construct_compat.csfield_const` shim in the source.
  #   * ipsw-parser 1.5.0 already provides every symbol used here
  #     (`dsc.create_device_support_layout`/`get_device_support_path`, IPSW,
  #     BuildIdentity/BuildManifest, NoSuchBuildIdentityError).
  pythonRelaxDeps = [
    "construct-typing"
    "ipsw_parser"
  ];

  # pyusb locates libusb-1.0.so via ctypes at runtime, which needs it on the
  # loader path in a Nix environment (Recovery/DFU support).  gio and xdg-open
  # are shelled out to by `webdav --mount`.
  postFixup = lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
    wrapProgram $out/bin/pymobiledevice3 \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libusb1 ]} \
      --prefix PATH : ${
        lib.makeBinPath [
          glib
          xdg-utils
        ]
      }
  '';

  pythonImportsCheck = [ "pymobiledevice3" ];

  # Upstream CI only runs the `cli` mark (the rest need a physical device), but
  # pytest still imports every test module, so the `test` extra is required.
  nativeCheckInputs = [
    httpx
    pytest-asyncio
    pytestCheckHook
  ];

  enabledTestMarks = [ "cli" ];

  meta = {
    changelog = "https://github.com/doronz88/pymobiledevice3/releases/tag/${src.tag}";
    description = "Pure python3 implementation for working with iDevices (iPhone, etc.)";
    homepage = "https://github.com/doronz88/pymobiledevice3";
    license = lib.licenses.gpl3Plus;
    mainProgram = "pymobiledevice3";
    maintainers = [ lib.maintainers.dotlambda ];
  };
}
