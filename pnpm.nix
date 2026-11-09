# pnpm 12, as the prebuilt binary upstream publishes to npm.
#
# pnpm 12 is a Rust rewrite: the `pnpm` npm package no longer contains a JS
# implementation, only a shim that runs the platform's `@pnpm/exe.<os>-<arch>`
# binary. nixpkgs builds pnpm_12 from source (generic-rust.nix) but lags the
# version Reactive Resume pins in package.json `packageManager`, and a cargo
# build of pnpm on the Pi costs far more than this. autoPatchelf points the
# glibc-linked binary at the Nix loader.
#
# `nodejs-slim` is what nixpkgs' fetchPnpmDeps expects on a pnpm derivation
# (it puts it on PATH and builds pnpm-fixup-state-db against it).
{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  nodejs-slim,
}:

let
  version = "12.16.1"; # == package.json packageManager
  platforms = {
    x86_64-linux = {
      arch = "linux-x64";
      hash = "sha256-yenUX3hE0y+HF8TKx8Ua7ipzGM1Wr9leslMSWwnWvDI=";
    };
    aarch64-linux = {
      arch = "linux-arm64";
      hash = "sha256-KJWqwZ4ksX5w2EylfJNPXfzuIpLGGR/jrGJHBlhrgM0=";
    };
  };
  platform = platforms.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "pnpm";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@pnpm/exe.${platform.arch}/-/exe.${platform.arch}-${version}.tgz";
    inherit (platform) hash;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 pnpm $out/bin/pnpm
    ln -s pnpm $out/bin/pn
    runHook postInstall
  '';

  dontStrip = true;

  passthru = {
    inherit nodejs-slim;
    majorVersion = lib.versions.major version;
  };

  meta = {
    description = "Fast, disk space efficient package manager for JavaScript";
    homepage = "https://pnpm.io/";
    license = lib.licenses.mit;
    mainProgram = "pnpm";
    platforms = builtins.attrNames platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
