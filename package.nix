# Reactive Resume (rxresu.me) v5 — native build from source.
#
# v5 is a pnpm@11 + turbo monorepo (apps/{web,server} + 16 workspace packages).
# The upstream install path is Docker-only; this builds it the Nix way:
#   1. fetchPnpmDeps — fixed-output derivation fetching the whole pnpm store.
#   2. pnpmConfigHook — offline `pnpm install --frozen-lockfile` from that store.
#   3. turbo build --filter=web --filter=server — Vite SPA (apps/web/dist) +
#      tsdown server bundle (apps/server/dist/index.mjs, serves the SPA statically).
#
# Notes:
# - Drizzle ORM + raw-SQL migrations (migrations/), no Prisma engine / codegen.
#   The server self-applies migrations on boot (apps/server/src/startup/checks.ts),
#   locating migrations/ by walking parent dirs from the server module — so it MUST
#   sit at the package root (share/reactive-resume/migrations).
# - configHook installs with --ignore-scripts, so bcrypt's native addon is not
#   compiled during install; we `pnpm rebuild bcrypt` explicitly (node-gyp, offline
#   via npm_config_nodedir). sharp/esbuild/msgpackr-extract ship prebuilt binaries.
# - MUST use pnpm 11.10.0 (the version in package.json's packageManager field):
#   nixpkgs' pnpm 10.28 cannot reconcile the pnpm-11-written `patchedDependencies`
#   entry (@react-pdf/textkit) against the v9.0 lockfile and aborts with
#   ERR_PNPM_LOCKFILE_CONFIG_MISMATCH. We build 11.10.0 from the same generic
#   builder and drive both the deps FOD and the config hook with it.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs_24,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  python3,
  # Build the SPA under a URL sub-path (Vite `base`, router basepath, and the
  # client/server absolute-URL builders all derive from this — see
  # patches/base-path-support.patch). "/" = served at the web root (default);
  # e.g. "/rxresume/" = served behind a reverse-proxy at that prefix. MUST keep
  # the trailing slash for a sub-path (Vite's `base` convention).
  appBasePath ? "/",
}:

let
  # pnpm 11.10.0 (matches the repo's packageManager pin + lockfile). Reuse the
  # nixpkgs pnpm derivation, swap the npm tarball. Relax preConfigure: pnpm 11
  # dropped the bundled `dist/reflink.*node` the base rule `rm -r`s (would error
  # on the missing glob), while `dist/vendor` (Windows fastlist blobs) still exists.
  pnpm_11 = pnpm.overrideAttrs (_: rec {
    version = "11.10.0";
    src = fetchurl {
      url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
      hash = "sha256-YgtmBepPYvxWptCphzP0eQcdAyHgPkhrUix+mnRhdDE=";
    };
    preConfigure = "rm -rf dist/reflink.*node dist/vendor";
    # Two pnpm-11-vs-nixpkgs-pnpm-fetcher incompatibilities, both fixed by a thin
    # bin/pnpm wrapper:
    #   1. pnpm 11 renamed the entrypoints bin/pnpm.cjs → bin/pnpm.mjs (the base
    #      installPhase symlinks the now-missing .cjs).
    #   2. The nixpkgs fetcher + configHook issue `pnpm config set
    #      manage-package-manager-versions false` in GLOBAL scope, which pnpm 11
    #      rejects (ERR_PNPM_CONFIG_SET_UNSUPPORTED_YAML_CONFIG_KEY — the key moved
    #      to workspace scope). We already run pnpm 11 (== packageManager pin), so
    #      that auto-switch guard is moot; swallow just that one invocation.
    # exec the .mjs via an explicit node so we don't depend on its shebang/PATH.
    installPhase = ''
      runHook preInstall
      install -d $out/{bin,libexec}
      cp -R . $out/libexec/pnpm
      chmod +x $out/libexec/pnpm/bin/*.mjs
      cat > $out/bin/pnpm <<EOF
      #!/bin/sh
      if [ "\$1" = config ] && [ "\$2" = set ] && [ "\$3" = manage-package-manager-versions ]; then exit 0; fi
      exec ${nodejs_24}/bin/node $out/libexec/pnpm/bin/pnpm.mjs "\$@"
      EOF
      chmod +x $out/bin/pnpm
      ln -s $out/libexec/pnpm/bin/pnpx.mjs $out/bin/pnpx
      runHook postInstall
    '';
    postInstall = "";
  });
in
stdenv.mkDerivation (finalAttrs: {
  pname = "reactive-resume";
  version = "5.2.1";

  src = fetchFromGitHub {
    owner = "amruthpillai";
    repo = "reactive-resume";
    rev = "v${finalAttrs.version}";
    hash = "sha256-gMux1R7RKNCOnjMqbnWUxfu1GAP9qVSP4PrWGgQ6x30=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 3;
    hash = "sha256-K5WUMzL8Ntb/SpcFDVlSsPXdXqSzoKpnshG92egqim8=";
  };

  # Base-path (URL sub-path) support. Rewrites the ~13 client/server sites that
  # hardcode a root origin (Vite `base`, TanStack Router basepath, the oRPC +
  # better-auth client base, public-share/avatar URLs, and the server's
  # APP_URL-joined PDF/storage/login URLs) to derive from the base path. The
  # patch does not touch package.json / pnpm-lock.yaml, so pnpmDeps is unchanged.
  # It is a no-op at APP_BASE_PATH=/ (the default), so the default build is the
  # stock root-served app.
  patches = [ ./patches/base-path-support.patch ];

  # oRPC request batching (BatchLinkPlugin) embeds each sub-request's ABSOLUTE
  # URL — including the base path — in the batch POST body. Behind a reverse
  # proxy that strips the base-path prefix before forwarding, the backend (RPC
  # handler mounted at /api/rpc) cannot route those inner /<base>/api/rpc/...
  # paths, so every batched query fails with 404 "No procedure matched". The
  # symptom is a dashboard whose initial (batched) draw is empty while single
  # requests (e.g. a sort/filter change) work. Disable batching for sub-path
  # builds so each query is an individual request whose outer path the proxy
  # strips correctly. No-op at APP_BASE_PATH=/ (batching left intact for the
  # stock root-served app, where the embedded URLs resolve fine).
  postPatch = lib.optionalString (appBasePath != "/") ''
    substituteInPlace apps/web/src/libs/orpc/client.ts \
      --replace-fail 'groups: [{ condition: () => true, context: {} }]' \
                     'groups: [{ condition: () => false, context: {} }]'
  '';

  nativeBuildInputs = [
    nodejs_24
    pnpm_11
    pnpmConfigHook # uses pnpm_11 (only pnpm on PATH); reads $pnpmDeps
    python3 # node-gyp for bcrypt
  ];

  env = {
    TURBO_TELEMETRY_DISABLED = "1";
    CI = "1";
    # node-gyp builds bcrypt against these headers, fully offline.
    npm_config_nodedir = "${nodejs_24}";
    # Vite reads this in apps/web/vite.config.ts (`base`) at build time; the
    # patched client sources derive their router basepath + fetch bases from it.
    APP_BASE_PATH = appBasePath;
  };

  buildPhase = ''
    runHook preBuild

    # bcrypt's native addon is skipped by configHook (--ignore-scripts); compile
    # it now against the Nix node headers.
    pnpm rebuild bcrypt

    # Build only the web SPA + server bundle; turbo pulls in the workspace
    # packages they depend on transitively (keeps peak RAM down vs. all 16).
    # --env-mode=loose: turbo 2.x strips undeclared env vars from tasks by
    # default (strict mode), which would hide APP_BASE_PATH from `vite build`
    # (→ base always "/"). Loose passes the full build env through to the tasks.
    pnpm exec turbo run build --filter=web --filter=server --env-mode=loose

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Ship the built workspace tree wholesale: the tsdown server bundle
    # externalises npm deps, so node_modules (pnpm symlink farm, relative links
    # resolve within $out) must travel with it, alongside the web dist and the
    # migrations/ folder the boot-time migrator walks up to find.
    # Copy every workspace member (apps/*, packages/*, tooling per
    # pnpm-workspace.yaml) so the @reactive-resume/* symlinks in node_modules/.pnpm
    # all resolve — omitting `tooling` leaves one dangling symlink that trips the
    # stdenv noBrokenSymlinks check.
    mkdir -p $out/share/reactive-resume
    cp -a \
      node_modules \
      apps \
      packages \
      tooling \
      migrations \
      package.json pnpm-lock.yaml pnpm-workspace.yaml \
      $out/share/reactive-resume/

    mkdir -p $out/bin
    cat > $out/bin/reactive-resume <<EOF
    #!${stdenv.shell}
    exec ${nodejs_24}/bin/node $out/share/reactive-resume/apps/server/dist/index.mjs "\$@"
    EOF
    chmod +x $out/bin/reactive-resume

    runHook postInstall
  '';

  # node_modules is already built for this platform; nothing to strip/patch that
  # the pnpm store hasn't handled. Avoid fixup mangling the bcrypt .node.
  dontStrip = true;

  meta = {
    description = "A free and open-source resume builder (self-hosted)";
    homepage = "https://rxresu.me";
    license = lib.licenses.mit;
    mainProgram = "reactive-resume";
    platforms = lib.platforms.linux;
  };
})
