{
  description = "WPS Office CN Standalone AppImage Build Configuration";

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

      wpsBuildInputs = with pkgs; [
        alsa-lib
        libjpeg
        libtool
        libxkbcommon
        nspr
        nss
        udev
        gtk3
        libgbm
        libusb1
        unixodbc
        libsForQt5.qtbase
        libxdamage
        libxtst
        libxv
        libx11
        libxext
        libxrender
        libxrandr
        libxfixes
        libxcursor
        libxi
        libXcomposite
        libXinerama
        libxcb
        xcbutilwm
        xcbutilimage
        xcbutilkeysyms
        xcbutilrenderutil
        cups
        dbus
        pango
        mariadb-connector-c
        libva
      ];

      wpsStandalone = pkgs.stdenv.mkDerivation {
        pname = "wps-office-cn";
        version = wpsConfig.version;
        src = debFile;

        nativeBuildInputs = with pkgs; [
          dpkg
          autoPatchelfHook
        ];

        buildInputs = wpsBuildInputs;

        # Add dlopen runtime dependencies to RPATH of binaries
        runtimeDependencies = map pkgs.lib.getLib [
          pkgs.cups
          pkgs.dbus
          pkgs.pango
        ];

        dontWrapQtApps = true;
        stripAllList = [ "opt" ];

        autoPatchelfIgnoreMissingDeps = [
          "libksailite.so"
        ];

        unpackPhase = ''
          runHook preUnpack
          dpkg-deb -x $src .
          runHook postUnpack
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out

          # Remove bundled libraries that may conflict with host graphics and glibc
          rm -rf usr/share/{fonts,locale} || true
          rm -f usr/bin/misc || true
          rm -rf opt/kingsoft/wps-office/{desktops,INSTALL} || true
          rm -f opt/kingsoft/wps-office/office6/lib{peony-wpsprint-menu-plugin,bz2,jpeg,stdc++,gcc_s,odbc*,dbus-1}.so* || true

          cp -r opt $out/
          cp -r usr/{bin,share} $out/

          for i in $out/bin/*; do
            substituteInPlace $i \
              --replace-fail "/opt/kingsoft/wps-office" "$out/opt/kingsoft/wps-office"

            # Remove output suppression so errors appear in terminal
            sed -i 's|> /dev/null 2>&1||g' "$i"
            sed -i 's|&> /dev/null||g' "$i"
          done

          for i in $out/share/applications/*; do
            substituteInPlace $i \
              --replace-fail "/usr/bin" "$out/bin"
          done

          addAutoPatchelfSearchPath "$out/opt/kingsoft/wps-office/office6"
          addAutoPatchelfSearchPath "$out/opt/kingsoft/wps-office/office6/hardware"
          if [ -d "$out/opt/kingsoft/wps-office/office6/addons" ]; then
            addAutoPatchelfSearchPath "$out/opt/kingsoft/wps-office/office6/addons"
          fi

          runHook postInstall
        '';

        preFixup = ''
          if [ -f "$out/opt/kingsoft/wps-office/office6/addons/cef/libcef.so" ]; then
            patchelf --add-needed libudev.so.1 "$out/opt/kingsoft/wps-office/office6/addons/cef/libcef.so" || true
          fi

          if [ -f "$out/opt/kingsoft/wps-office/office6/libFontWatermark.so" ]; then
            patchelf --replace-needed libmysqlclient.so.18 libmysqlclient.so "$out/opt/kingsoft/wps-office/office6/libFontWatermark.so" || true
            patchelf --add-rpath "${pkgs.mariadb-connector-c}/lib/mariadb:${pkgs.mariadb-connector-c}/lib" "$out/opt/kingsoft/wps-office/office6/libFontWatermark.so" || true
          fi

          for i in $out/bin/*; do
            substituteInPlace $i \
              --replace-warn '[ $haveConf -eq 1 ] &&' '[ ! $currentMode ] ||'
          done
        '';

        postFixup = ''
          # Provide explicit symlinks in office6/ for unversioned dlopen lookups
          ln -sf ${pkgs.dbus.lib}/lib/libdbus-1.so.3 $out/opt/kingsoft/wps-office/office6/libdbus-1.so.3
          ln -sf ${pkgs.dbus.lib}/lib/libdbus-1.so.3 $out/opt/kingsoft/wps-office/office6/libdbus-1.so

          ln -sf ${pkgs.cups.lib}/lib/libcups.so.2 $out/opt/kingsoft/wps-office/office6/libcups.so.2
          ln -sf ${pkgs.cups.lib}/lib/libcups.so.2 $out/opt/kingsoft/wps-office/office6/libcups.so
        '';
      };

      appimageRuntime = pkgs.fetchurl {
        url = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64";
        hash = "sha256-FW9L296cUtAYFGAAE+Cic/ARjcLemJdfPIxjQn7HkHQ=";
      };

      # Upstream static PRoot binary used when unprivileged bubblewrap is unavailable
      prootStatic = pkgs.fetchurl {
        url = "https://github.com/proot-me/proot/releases/download/v5.5.0/proot";
        hash = "sha256-2xhTAKnaq7zoasp2MtjH/cQkn28VMXGVQBO3DF9JHsA=";
      };

      appimage = pkgs.stdenv.mkDerivation {
        name = "WPS-Office-CN-${wpsStandalone.version}-x86_64.AppImage";
        nativeBuildInputs = [
          pkgs.squashfsTools
          pkgs.binutils
          pkgs.coreutils
          pkgs.zsync
        ];
        closureInfo = pkgs.closureInfo { rootPaths = [ wpsStandalone ]; };

        buildCommand = ''
          mkdir -p AppDir/nix/store
          while IFS= read -r path; do
            cp -a "$path" AppDir/nix/store/
          done < "$closureInfo/store-paths"

          chmod -R u+w AppDir/nix/store
          rm -rf AppDir/nix/store/*/{share/doc,share/man,share/info,include,lib/pkgconfig}
          find AppDir/nix/store -type f \( -name "*.a" -o -name "*.la" \) -delete
          find AppDir/nix/store -type f \( -name "*.so*" -o -perm -0100 \) -exec strip --strip-unneeded {} + 2>/dev/null || true

          # Bundle static bubblewrap and static proot
          cp ${pkgs.pkgsStatic.bubblewrap}/bin/bwrap AppDir/bwrap
          chmod +x AppDir/bwrap
          strip --strip-unneeded AppDir/bwrap 2>/dev/null || true

          cp ${prootStatic} AppDir/proot
          chmod +x AppDir/proot

          # 1. Desktop integration setup
          mkdir -p AppDir/usr/share
          cp -r "${wpsStandalone}/share/"* AppDir/usr/share/
          ln -sf usr/share/applications/wps-office-prometheus.desktop AppDir/
          ln -sf usr/share/icons/hicolor/scalable/apps/wps-office2023-kprometheus.svg AppDir/
          ln -sf wps-office2023-kprometheus.png AppDir/.DirIcon

          # 2. Binary symlinks
          mkdir -p AppDir/bin
          ln -s ${wpsStandalone}/bin/wps AppDir/bin/wps
          ln -s ${wpsStandalone}/bin/et AppDir/bin/et
          ln -s ${wpsStandalone}/bin/wpp AppDir/bin/wpp
          ln -s ${wpsStandalone}/bin/wpspdf AppDir/bin/wpspdf
          ln -s ${wpsStandalone}/bin/wps AppDir/entrypoint

          # 3. AppRun multiplexer script with shared binds
          cat << 'EOF' > AppDir/AppRun
          #!/usr/bin/env bash
          set -e

          # 1. Accurately locate mounted AppDir root
          HERE="''${APPDIR:-$(dirname "$(readlink -f "''${BASH_SOURCE[0]}")")}"
          INVOKED_NAME="$(basename "''${ARGV0:-$0}")"

          # 2. Determine target binary without relying on host /nix existence
          case "$INVOKED_NAME" in
            et|wpp|wpspdf|wps)
              TARGET="$(readlink "$HERE/bin/$INVOKED_NAME")"
              ;;
            *)
              case "''${1:-}" in
                et|wpp|wpspdf|wps)
                  TARGET="$(readlink "$HERE/bin/$1")"
                  shift
                  ;;
                *)
                  TARGET="$(readlink "$HERE/entrypoint")"
                  ;;
              esac
              ;;
          esac

          # 3. Fallback to compile-time Nix store path if symlink resolution is empty
          TARGET="''${TARGET:-${wpsStandalone}/bin/wps}"

          # Shared environment setup for both launchers
          export XDG_SESSION_TYPE=x11
          export QT_QPA_PLATFORM=xcb
          unset WAYLAND_DISPLAY

          WPS_ROOT="${wpsStandalone}/opt/kingsoft/wps-office/office6"
          export QT_PLUGIN_PATH="$WPS_ROOT/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
          export LD_LIBRARY_PATH="$WPS_ROOT:$WPS_ROOT/addons/cef''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

          if [ -z "$PULSE_SERVER" ]; then
            if [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ]; then
              export PULSE_SERVER="unix:''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
            elif [ -S "/run/user/$(id -u)/pulse/native" ]; then
              export PULSE_SERVER="unix:/run/user/$(id -u)/pulse/native"
            fi
          fi

          # Fast path: Native NixOS host execution
          if [ -x "$TARGET" ]; then
            exec "$TARGET" "$@"
          fi

          # Collect shared filesystem mount paths (storage, system fonts, DRI drivers)
          COMMON_BINDS=()
          for d in /media /mnt /run/media; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /usr/share/fonts /usr/local/share/fonts /etc/fonts; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          for d in /run/opengl-driver/lib/dri /usr/lib/x86_64-linux-gnu/dri /usr/lib64/dri /usr/lib/dri; do
            [ -d "$d" ] && COMMON_BINDS+=("$d")
          done

          # Probe whether unprivileged bubblewrap can construct a user namespace
          CAN_BWRAP=0
          if [ -x "$HERE/bwrap" ] && "$HERE/bwrap" --ro-bind / / true >/dev/null 2>&1; then
            CAN_BWRAP=1
          fi

          # Execution branches: bubblewrap first, fallback to proot
          if [ "$CAN_BWRAP" -eq 1 ]; then
            BWRAP_ARGS=()
            for d in /*; do
              case "$d" in
                /proc|/dev|/sys|/tmp|/run|/var|/nix|/home|/root|/media|/mnt) ;;
                *) [ -d "$d" ] && BWRAP_ARGS+=(--ro-bind "$d" "$d") ;;
              esac
            done

            for d in "''${COMMON_BINDS[@]}"; do
              BWRAP_ARGS+=(--bind "$d" "$d")
            done

            exec "$HERE/bwrap" \
              "''${BWRAP_ARGS[@]}" \
              --proc /proc \
              --dev-bind /dev /dev \
              --ro-bind /sys /sys \
              --bind /tmp /tmp \
              --bind /run /run \
              --bind /var /var \
              --bind "$HOME" "$HOME" \
              --dir /nix \
              --ro-bind "$HERE/nix/store" /nix/store \
              -- "$TARGET" "$@"
          elif [ -x "$HERE/proot" ]; then
            PROOT_ARGS=(-r / -b "$HERE/nix/store:/nix/store")

            for d in /dev /proc /sys /tmp /run /var "$HOME"; do
              [ -d "$d" ] && PROOT_ARGS+=(-b "$d:$d")
            done

            for d in "''${COMMON_BINDS[@]}"; do
              PROOT_ARGS+=(-b "$d:$d")
            done

            exec "$HERE/proot" \
              "''${PROOT_ARGS[@]}" \
              "$TARGET" "$@"
          else
            echo "Error: Neither bwrap nor proot is functional on this system." >&2
            exit 1
          fi
          EOF
          chmod +x AppDir/AppRun

          # 4. Pack SquashFS filesystem
          mksquashfs AppDir squashfs.img \
            -root-owned -noappend \
            -comp zstd -b 1M -Xcompression-level 22

          # 5. Assemble AppImage binary directly with virgin runtime
          # DO NOT run objcopy on runtime: objcopy zeroes out ELF e_ident[EI_PAD] (offset 8..15),
          # which destroys the official AppImage Type 2 magic bytes ('AI\x02').
          mkdir -p "$out"
          FINAL_APPIMAGE="$out/WPS-Office-CN-${wpsStandalone.version}-x86_64.AppImage"
          cat ${appimageRuntime} squashfs.img > "$FINAL_APPIMAGE"
          chmod +x "$FINAL_APPIMAGE"

          # 6. Generate zsync delta file directly from the final AppImage
          cd "$out"
          zsyncmake -u "$(basename "$FINAL_APPIMAGE")" "$FINAL_APPIMAGE"
        '';
      };
    in
      {
        packages.${system} = {
          default = appimage;
          inherit appimage wpsStandalone;
        };
      };
}
