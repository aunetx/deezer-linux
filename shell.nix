{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  buildInputs = with pkgs; [
    gnumake
    p7zip
    nodejs
    jq
    wget
  ];
}
