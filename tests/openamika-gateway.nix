{ pkgs }:
pkgs.runCommand "openamika-gateway-tests"
  {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.aiohttp ])) ];
  }
  ''
    cp ${../scripts/openamika/gateway.py} gateway.py
    cp ${../scripts/openamika/test_gateway.py} test_gateway.py
    python -m unittest -v test_gateway
    touch $out
  ''
