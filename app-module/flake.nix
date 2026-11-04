{
  description = "Feedback app for Basecamp — crypto core (feedback_core) + QML UI (feedback_ui)";

  inputs = {
    nixpkgs.follows = "logos-cpp-sdk/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
    logos-liblogos = {
      url = "github:logos-co/logos-liblogos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, logos-cpp-sdk, logos-liblogos }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        logosSdk = logos-cpp-sdk.packages.${system}.default;
        logosHeaders = logos-liblogos.packages.${system}.default;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config pkgs.qt6.qtbase pkgs.libsodium ];
          shellHook = ''
            export LOGOS_CPP_SDK_ROOT="${logosSdk}"
            export LOGOS_LIBLOGOS_HEADERS="${logosHeaders}/include"
          '';
        };

        packages = {
          # feedback_core: the native crypto plugin (lib/feedback_core_plugin.so + manifest)
          lib = pkgs.stdenv.mkDerivation {
            pname = "feedback-core";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config ];
            buildInputs = [ pkgs.qt6.qtbase pkgs.libsodium ];
            cmakeFlags = [ "-GNinja" "-DCMAKE_BUILD_TYPE=Release" ];
            dontWrapQtApps = true;
            preConfigure = ''
              export LOGOS_CPP_SDK_ROOT="${logosSdk}"
              export LOGOS_LIBLOGOS_HEADERS="${logosHeaders}/include"
            '';
            buildPhase = ''
              cmake --build . --target feedback_core_plugin -j$NIX_BUILD_CORES
            '';
            installPhase = ''
              mkdir -p $out/lib
              cp core/feedback_core_plugin.so $out/lib/
              cp ${./core/manifest.json} $out/lib/manifest.json
              cp ${./metadata.json} $out/lib/metadata.json
            '';
          };

          # feedback_ui: the QML UI (install-only; delivery + feedback_core are runtime deps)
          ui = pkgs.stdenv.mkDerivation {
            pname = "feedback-ui";
            version = "0.1.0";
            src = ./ui;
            dontBuild = true;
            dontConfigure = true;
            installPhase = ''
              mkdir -p $out/lib
              cp Main.qml $out/lib/
              cp metadata.json $out/lib/
              cp manifest.json $out/lib/
            '';
          };

          default = self.packages.${system}.lib;
        };
      }
    );
}
