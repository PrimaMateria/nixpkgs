{ lib
, backports-strenum
, buildPythonPackage
, fetchFromGitHub
, pytestCheckHook
, pythonOlder
, setuptools
}:

buildPythonPackage rec {
  pname = "archinfo";
  version = "9.2.77";
  pyproject = true;

  disabled = pythonOlder "3.8";

  src = fetchFromGitHub {
    owner = "angr";
    repo = pname;
    rev = "refs/tags/v${version}";
    hash = "sha256-uTkPDhk4Ugyb9HV/0PMwWpuNajpzfTn1dg7gsQnc/zg=";
  };

  nativeBuildInputs = [
    setuptools
  ];

  propagatedBuildInputs = lib.optionals (pythonOlder "3.11") [
    backports-strenum
  ];

  nativeCheckInputs = [
    pytestCheckHook
  ];

  pythonImportsCheck = [
    "archinfo"
  ];

  meta = with lib; {
    description = "Classes with architecture-specific information";
    homepage = "https://github.com/angr/archinfo";
    license = with licenses; [ bsd2 ];
    maintainers = with maintainers; [ fab ];
  };
}
