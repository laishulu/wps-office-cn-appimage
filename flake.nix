{
  description = "WPS Office CN Native FHS AppImage Build Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      wpsConfig = {
        version = "12.1.2.29183";
        url = "https://wps-linux-personal.wpscdn.cn/wps/download/ep/Linux2023/29183/wps-office_12.1.2.29183.AK.preread.sw.Personal_806791_amd64.deb";
        hash = "sha256-d/+9wb52yDThhTwn/5Bj5J1dOx8wsgbXhXYbW/VgyDs=";
      };

      debFile =
        if pkgs.lib.hasPrefix "https://wps-linux-personal.wpscdn.cn" wpsConfig.url then
          pkgs.runCommandLocal "wps-office-${wpsConfig.version}.deb"
            {
              outputHashAlgo = if pkgs.lib.hasPrefix "sha512-" wpsConfig.hash then "sha512" else "sha256";
              outputHash = wpsConfig.hash;
              nativeBuildInputs = [ pkgs.curl pkgs.coreutils ];
              impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars;
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            }
            ''
              readonly SECURITY_KEY="7f8faaaa468174dc1c9cd62e5f218a5b"
              uri="${pkgs.lib.removePrefix "https://wps-linux-personal.wpscdn.cn" wpsConfig.url}"
              timestamp10=$(date '+%s')
              md5hash=($(printf '%s' "$SECURITY_KEY$uri$timestamp10" | md5sum))

              curl -fSL --retry 3 --retry-delay 3 \
                "${wpsConfig.url}?t=$timestamp10&k=$md5hash" > $out
            ''
        else
          pkgs.fetchurl {
            url = wpsConfig.url;
            hash = wpsConfig.hash;
          };

      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/latest/download/runtime-x86_64";
        hash = "sha256-YXqncxTVfIuOT66cPws1r3sw1VKctp6Y9k+SUQ7ZikY=";
      };

      appimagetool = pkgs.fetchurl {
        url = "https://github.com/AppImage/appimagetool/releases/latest/download/appimagetool-x86_64.AppImage";
        hash = "sha256-lcvnzOlxf86QxITjQFLufH8ddjWzPBJSW0d2gmp9KbY=";
      };

      appimage = pkgs.stdenvNoCC.mkDerivation {
        pname = "wps-office-cn-appimage";
        version = wpsConfig.version;
        src = debFile;

        nativeBuildInputs = with pkgs; [
          binutils
          gnutar
          xz
          patchelf
          file
          zsync
        ];

        # Disable automatic patchelf and strip to keep native FHS dynamic linking
        dontPatchELF = true;
        dontStrip = true;

        unpackPhase = ''
          runHook preUnpack
          ar x $src
          tar -xf data.tar.xz
          runHook postUnpack
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p AppDir/opt/kingsoft/wps-office AppDir/usr/bin AppDir/usr/share AppDir/etc

          # 1. Copy core office binaries
          cp -r opt/kingsoft/wps-office/office6 AppDir/opt/kingsoft/wps-office/

          # Remove obsolete bundled libraries to prevent conflicts with host graphics/glibc
          rm -f AppDir/opt/kingsoft/wps-office/office6/libstdc++.so* || true
          rm -f AppDir/opt/kingsoft/wps-office/office6/libjpeg.so* || true
          rm -f AppDir/opt/kingsoft/wps-office/office6/libbz2.so* || true
          rm -f AppDir/opt/kingsoft/wps-office/office6/libpeony-wpsprint-menu-plugin.so* || true

          # Ensure libcef.so explicitly records libudev.so.1 as a needed dependency
          if [ -f AppDir/opt/kingsoft/wps-office/office6/addons/cef/libcef.so ]; then
            patchelf --add-needed libudev.so.1 AppDir/opt/kingsoft/wps-office/office6/addons/cef/libcef.so || true
          fi

          # 2. Copy and patch launcher scripts
          cp -r usr/bin/* AppDir/usr/bin/
          rm -f AppDir/usr/bin/misc || true

          for script in AppDir/usr/bin/*; do
            if [ -f "$script" ]; then
              # Point installation path to AppImage runtime mount root
              sed -i "s|/opt/kingsoft/wps-office|\''${APPDIR}/opt/kingsoft/wps-office|g" "$script"

              # Prevent the upstream wrapper from dropping external LD_LIBRARY_PATH entries
              sed -i 's|export LD_LIBRARY_PATH=\([^$].*\)|export LD_LIBRARY_PATH=\1:$LD_LIBRARY_PATH|g' "$script"
              sed -i 's|LD_LIBRARY_PATH=\([^$].*\)|LD_LIBRARY_PATH=\1:$LD_LIBRARY_PATH|g' "$script"

              # Remove stdout/stderr redirection for easier diagnosis
              sed -i 's|> /dev/null 2>&1||g' "$script"
              sed -i 's|&> /dev/null||g' "$script"
            fi
          done

          # 3. Copy desktop, icons, and MIME assets
          cp -r usr/share/* AppDir/usr/share/
          cp -r etc/* AppDir/etc/ 2>/dev/null || true

          # Add standard Office category to desktop entry if missing
          sed -i 's|^Categories=.*|&Office;|' AppDir/usr/share/applications/wps-office-prometheus.desktop

          # 4. Create AppDir root specifications
          ln -sf usr/share/applications/wps-office-prometheus.desktop AppDir/wps-office-prometheus.desktop
          ln -sf usr/share/icons/hicolor/scalable/apps/wps-office2023-kprometheus.svg AppDir/wps-office2023-kprometheus.svg
          ln -sf wps-office2023-kprometheus.svg AppDir/.DirIcon

          # 5. Create AppRun entrypoint
          cat << 'EOF' > AppDir/AppRun
          #!/usr/bin/env bash
          set -e

          export APPDIR="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
          INVOKED_NAME="$(basename "''${ARGV0:-$0}")"

          WPS_BASE="$APPDIR/opt/kingsoft/wps-office"
          WPS_OPT="$WPS_BASE/office6"
          CEF_DIR="$WPS_OPT/addons/cef"

          # Force XCB (X11) backend to avoid missing wayland platform plugin crashes
          export QT_QPA_PLATFORM="xcb"
          export GDK_BACKEND="x11"
          unset WAYLAND_DISPLAY

          # Specify Qt platform and component plugin directories
          export QT_QPA_PLATFORM_PLUGIN_PATH="$WPS_OPT/plugins/platforms"
          export QT_PLUGIN_PATH="$WPS_OPT/plugins"

          # Chromium Embedded Framework runtime variables
          export CEF_PATH="$CEF_DIR"
          export CHROMIUM_DISABLE_SANDBOX=1
          export QTWEBENGINE_DISABLE_SANDBOX=1

          export PATH="$APPDIR/usr/bin:$PATH"

          # Assemble dynamic linker search paths
          INTERNAL_LIBS="$CEF_DIR:$WPS_OPT:$WPS_OPT/plugins/platforms:$WPS_OPT/hardware"
          if [ -n "$NIX_LD_LIBRARY_PATH" ]; then
            export LD_LIBRARY_PATH="$INTERNAL_LIBS:$NIX_LD_LIBRARY_PATH''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          else
            export LD_LIBRARY_PATH="$INTERNAL_LIBS''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          fi

          export XDG_DATA_DIRS="$APPDIR/usr/share:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

          TARGET=""
          case "$INVOKED_NAME" in
            et|wpp|wpspdf|wps)
              TARGET="$APPDIR/usr/bin/$INVOKED_NAME"
              ;;
            *)
              case "''${1:-}" in
                et|wpp|wpspdf|wps)
                  TARGET="$APPDIR/usr/bin/$1"
                  shift
                  ;;
                *)
                  TARGET="$APPDIR/usr/bin/wps"
                  ;;
              esac
              ;;
          esac

          exec "$TARGET" --no-sandbox --disable-gpu-sandbox "$@"
          EOF
          chmod +x AppDir/AppRun

          # 6. Package AppImage using appimagetool
          install -m755 ${appimagetool} ./appimagetool

          mkdir -p "$out"
          FINAL_APPIMAGE="$out/WPS-Office-CN-${wpsConfig.version}-x86_64.AppImage"

          ARCH=x86_64 ./appimagetool --appimage-extract-and-run \
            --runtime-file "${appimageRuntime}" \
            -u "gh-releases-zsync|laishulu|wps-office-cn-appimage|latest|*x86_64.AppImage.zsync" \
            AppDir "$FINAL_APPIMAGE"

          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"
          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Standalone native FHS AppImage of Kingsoft WPS Office CN";
          homepage = "https://linux.wps.cn";
          platforms = [ "x86_64-linux" ];
          license = licenses.unfree;
        };
      };
    in
    {
      packages.${system} = {
        default = appimage;
        inherit appimage;
      };
    };
}
