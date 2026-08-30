{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
  pkgVer ? "local",
  arch ? "x64",
  lib ? pkgs.lib,
}:

let

  src = ./. + "/artifacts/${arch}/linux${lib.optionalString (arch != "x64") "-${arch}"}-unpacked";

  deezer-desktop = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "deezer-desktop";
    version = pkgVer;
    inherit src;

    nativeBuildInputs = [
      pkgs.makeWrapper
    ];

    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -d $out/bin $out/share/deezer-desktop/resources $out/share/applications $out/share/icons/hicolor/scalable/apps

      cp $src/resources/dev.aunetx.deezer.desktop $out/share/applications/
      substituteInPlace $out/share/applications/dev.aunetx.deezer.desktop \
        --replace-fail "run.sh" "deezer-desktop"
      cp $src/resources/dev.aunetx.deezer.svg $out/share/icons/hicolor/scalable/apps/
      cp -r $src/resources/{app.asar,linux} $out/share/deezer-desktop/resources/

      makeWrapper "${pkgs.lib.getExe pkgs.electron}" "$out/bin/deezer-desktop" \
        --inherit-argv0 \
        --add-flags "$out/share/deezer-desktop/resources/app.asar" \
        --set-default ELECTRON_FORCE_IS_PACKAGED 1 \
        --set DZ_RESOURCES_PATH "$out/share/deezer-desktop/resources"

      runHook postInstall
    '';

    meta = {
      description = "Unofficial Linux port of the music streaming application";
      homepage = "https://github.com/aunetx/deezer-linux";
      downloadPage = "https://github.com/aunetx/deezer-linux/releases";
      platforms = lib.platforms.linux;
      license = lib.licenses.unfree;
      mainProgram = "deezer-desktop";
    };
  });
in
{
  "deezer-desktop" = deezer-desktop;
  default = deezer-desktop;
}
