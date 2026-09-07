{ lib
, stdenv
, fetchFromGitHub
, fetchPnpmDeps
, pnpmConfigHook
, pnpm_11
, nodejs_24
, electron_43
, makeWrapper
, git
, openssh
, python3
, pkg-config
, alsa-lib
, atk
, cairo
, cups
, dbus
, expat
, ffmpeg
, gdk-pixbuf
, glib
, gtk3
, libdrm
, libnotify
, libpulseaudio
, libsecret
, libuuid
, libX11
, libxcb
, libXcomposite
, libXdamage
, libXext
, libXfixes
, libXrandr
, libXScrnSaver
, libXtst
, mesa
, nspr
, nss
, pango
, systemd
, wayland
, xdg-utils
, at-spi2-core
, at-spi2-atk
, xdotool
, xclip
, xvfb
, python3Packages
, makeDesktopItem
}:

let
  pname = "orca";
  version = "1.4.197";
  sourceRev = "38aab26e17f9eefb20b5d18eccbdf525fb54ff09";

  src = fetchFromGitHub {
    owner = "orual";
    repo = "orca";
    rev = sourceRev;
    hash = "sha256-zzi01T/sFia09mlop6Wv3s49oR4AhdTo6GMvsjwcyYQ=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-4hXjPzteTQGkAmxoLtTq9tzY1w3PuiTRv8vtAywB2+0=";
  };

  runtimeLibraries = [
    alsa-lib
    atk
    cairo
    cups
    dbus
    expat
    ffmpeg
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libnotify
    libpulseaudio
    libsecret
    libuuid
    libX11
    libxcb
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libXScrnSaver
    libXtst
    mesa
    nspr
    nss
    pango
    systemd
    wayland
    xdg-utils
  ];

  runtimeTools = [
    git
    openssh
    at-spi2-core
    at-spi2-atk
    xdotool
    xclip
    xvfb
    (python3.withPackages (ps: [ ps.pygobject3 ]))
  ];

  desktopItem = makeDesktopItem {
    name = "orca-ide";
    desktopName = "Orca";
    exec = "orca-ide %U";
    icon = "orca";
    comment = "ADE for working with a fleet of parallel agents";
    terminal = false;
    categories = [ "Development" ];
    startupWMClass = "orca";
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook
    electron_43
    makeWrapper
    git
    openssh
    python3
    pkg-config
  ];

  buildInputs = runtimeLibraries;

  pnpmDeps = pnpmDeps;

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    ELECTRON_INSTALL_PLATFORM = "linux";
    ELECTRON_INSTALL_ARCH = if stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
    npm_config_nodedir = "${electron_43.headers}";
    npm_config_build_from_source = "true";
    npm_config_electron_build_from_source = "true";
  };

  preBuild = ''
    # pnpmConfigHook deliberately installs with lifecycle scripts disabled. Make
    # the Nix-provided Electron distribution visible to Orca's strict native
    # runtime checks and electron-builder without downloading Electron.
    # The pinned nixpkgs Electron/Node toolchain uses glibc 2.42. Keep Orca's
    # checker active (including architecture, relocated-symbol, and libstdc++
    # checks), but compare symbol versions against this Nix runtime floor rather
    # than the upstream Ubuntu 20.04 floor.
    substituteInPlace config/scripts/verify-linux-glibc-floor.cjs \
      --replace-fail \
        'const MIN_GLIBC = Object.freeze([2, 31])' \
        'const MIN_GLIBC = Object.freeze([2, 42])'
    rm -rf node_modules/electron
    electronPackage=$(find node_modules/.pnpm -path '*/node_modules/electron' -type d -print -quit)
    test -n "$electronPackage"
    cp -aL "$electronPackage" node_modules/electron
    rm -rf node_modules/electron/dist
    cp -a ${electron_43.dist} node_modules/electron/dist
    printf 'electron\\n' > node_modules/electron/path.txt

    # pnpmConfigHook skips lifecycle scripts, so compile Orca's patched
    # node-pty explicitly for the build-host Node ABI before Vite smoke-loads
    # the daemon entry during build:desktop.
    pnpm rebuild node-pty
  '';

  buildPhase = ''
    runHook preBuild
    pnpm run build:desktop
    ELECTRON_OVERRIDE_DIST_PATH="$PWD/node_modules/electron/dist" \
      pnpm exec electron-builder --config config/electron-builder.config.cjs --linux --dir \
        --${if stdenv.hostPlatform.isAarch64 then "arm64" else "x64"} \
        -c.electronDist="$PWD/node_modules/electron/dist" \
        -c.electronVersion=${electron_43.version}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec $out/bin
    unpackedDir=dist/linux-unpacked
    if [ "${if stdenv.hostPlatform.isAarch64 then "arm64" else "x64"}" = arm64 ]; then
      unpackedDir=dist/linux-arm64-unpacked
    fi
    test -d "$unpackedDir"
    cp -a "$unpackedDir" $out/libexec/orca

    runtimePath=${lib.makeBinPath runtimeTools}
    sandbox=${electron_43}/libexec/electron/chrome-sandbox

    # The upstream Linux resource launcher is the CLI entrypoint. Keep it
    # intact, and expose the packaged Electron executable separately as the GUI.
    makeWrapper $out/libexec/orca/resources/bin/orca-ide $out/bin/orca \
      --prefix PATH : "$runtimePath"
    makeWrapper $out/libexec/orca/orca-ide $out/bin/orca-ide \
      --prefix PATH : "$runtimePath" \
      --set CHROME_DEVEL_SANDBOX "$sandbox" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

    install -Dm444 ${src}/resources/build/icon.png $out/share/icons/hicolor/512x512/apps/orca.png
    install -Dm444 ${desktopItem}/share/applications/orca-ide.desktop \
      $out/share/applications/orca-ide.desktop

    runHook postInstall
  '';

  passthru = { inherit src pnpmDeps; };

  meta = {
    description = "ADE for working with a fleet of parallel agents";
    homepage = "https://github.com/sjennings/orca";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ kevinpita ];
    mainProgram = "orca";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
}
