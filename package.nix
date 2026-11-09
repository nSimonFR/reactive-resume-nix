# Reactive Resume (rxresu.me) v6 — native build from source.
#
# v6 is a pnpm@12 + turbo monorepo (apps/{web,server,mobile} + ~17 workspace
# packages). The upstream install path is Docker-only; this builds it the Nix way:
#   1. fetchPnpmDeps — fixed-output derivation fetching the pnpm store, limited to
#      the projects the web + server build needs (pnpmWorkspaces; the Expo mobile
#      app and its React Native tree are left out, as the Dockerfile's
#      `turbo prune web server` does).
#   2. pnpmConfigHook — offline `pnpm install --frozen-lockfile` from that store.
#   3. turbo build --filter=web --filter=server — Vite SPA (apps/web/dist), the
#      prerendered marketing pages (apps/web/dist-prerender) and the tsdown server
#      bundle (apps/server/dist/index.mjs, serves the SPA statically).
#
# Notes:
# - Drizzle ORM + raw-SQL migrations (migrations/). The server self-applies them on
#   boot, locating migrations/ by walking parent dirs from the server module — so it
#   MUST sit at the package root (share/reactive-resume/migrations).
# - pnpm 12 is a native (Rust) binary; ./pnpm.nix packages the exact version
#   package.json `packageManager` pins. fetchPnpmDeps / pnpmConfigHook come from
#   the flake's own `nixpkgs-pnpm` input (passed in as `pnpmPkgs`), because only a
#   recent nixpkgs knows pnpm >= 11 (fetcherVersion 5, the v11 SQLite store index,
#   `pnpm_config_pm_on_fail=ignore` instead of the global config key pnpm 11+
#   rejects). That also makes the pnpmDeps hash independent of the consumer's
#   nixpkgs.
# - v6 hashes passwords with bcryptjs (pure JS): no node-gyp step any more.
# - The server renders PDFs in-process (Forme, @formepdf/core — WASM): no
#   Chromium/Gotenberg/printer service.
{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_24,
  autoPatchelfHook,
  pnpmPkgs,
  # Build the SPA under a URL sub-path (Vite `base`, router basepath, and the
  # client/server absolute-URL builders all derive from this — see
  # patches/base-path-support.patch). "/" = served at the web root (default);
  # e.g. "/rxresume/" = served behind a reverse-proxy at that prefix. MUST keep
  # the trailing slash for a sub-path (Vite's `base` convention).
  appBasePath ? "/",
}:

let
  pnpm_12 = pnpmPkgs.callPackage ./pnpm.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "reactive-resume";
  version = "6.1.0";

  src = fetchFromGitHub {
    owner = "amruthpillai";
    repo = "reactive-resume";
    rev = "v${finalAttrs.version}";
    hash = "sha256-W+/MUH6ld57vVm830V6Y0klWxLW+HaFiXs6Nyd8ft6U=";
  };

  # Only these projects (and their workspace deps, the trailing `...`) are
  # installed, in the FOD and again by pnpmConfigHook. The root project carries
  # turbo + vite-plus; tooling runs web's `capture:build` prebuild step.
  pnpmWorkspaces = [
    "reactive-resume"
    "web..."
    "server..."
    "@reactive-resume/tooling..."
  ];

  # Kept per-system (ci/renovate-update.sh rewrites one slot per host), but for 6.1.0
  # both slots are the SAME value: the nixpkgs-pnpm fetcher sets
  # pnpm_config_force_ignores_platform, so the store holds every platform's native
  # bindings and pnpmConfigHook picks the host's at install time. Measured on a
  # GitHub x86_64 runner and a GitHub arm64 runner (nic-os CI), both through this
  # flake's pinned `nixpkgs-pnpm`, which consumers do not override — so the hash no
  # longer depends on the consumer's nixpkgs either. If a bump ever makes them
  # differ again, compute aarch64 on the Pi: `bash ci/renovate-update.sh`.
  pnpmDeps = pnpmPkgs.fetchPnpmDeps {
    inherit (finalAttrs) version src pnpmWorkspaces;
    # fetchPnpmDeps names the FOD from pname alone; without the version a stale
    # hash silently reuses the previous release's deps from the store.
    pname = "${finalAttrs.pname}-${finalAttrs.version}";
    pnpm = pnpm_12;
    fetcherVersion = 5;
    # pnpm's default (16+ parallel tarballs, several hundred MB of buffers) gets
    # the FOD OOM-killed on a 4 GB Pi. Does not change the output.
    pnpm_config_network_concurrency = "4";
    hash =
      {
        x86_64-linux = "sha256-ykWVOY4FBScZ8r3pz1sqv67IaGt+7G5uQRf4zX47geE=";
        aarch64-linux = "sha256-ykWVOY4FBScZ8r3pz1sqv67IaGt+7G5uQRf4zX47geE=";
      }
      .${stdenv.hostPlatform.system};
  };

  # Base-path (URL sub-path) support, ported to v6. v6 has no base-path option
  # upstream. The patch sets Vite `base` + the router basepath, re-roots the oRPC /
  # Better Auth / MCP / upload / share URLs the client builds from
  # window.location.origin, and makes the server join APP_URL (which carries the
  # sub-path) instead of resolving root-absolute paths against it. The ~40
  # root-absolute public-file literals (`/templates/…`, `/logo/…`, …) are not
  # hunked one by one: a small Vite transform in vite.config.ts prefixes every
  # top-level entry of apps/web/public/, so new assets upstream need no re-anchor.
  # Better Auth keeps routing at the origin root (the proxy strips the prefix).
  # Applied only for a sub-path build; it does not touch package.json /
  # pnpm-lock.yaml, so pnpmDeps is shared by both builds.
  #
  # Dropped since v5: the error/not-found screen I18nProvider hunks (upstream now
  # wraps ErrorScreen itself) and the gallery thumbnail / home video / __root
  # icon hunks (covered by the Vite transform or moved back into index.html).
  patches = lib.optionals (appBasePath != "/") [ ./patches/base-path-support.patch ];

  # oRPC request batching (BatchLinkPlugin) embeds each sub-request's ABSOLUTE
  # URL — base path included — in the batch body. The proxy strips the prefix
  # from the outer request only, so the inner /<base>/api/rpc/... paths match no
  # procedure (404, empty dashboard). Disable batching for sub-path builds.
  #
  # The PWA manifest is a static public/ file Vite copies verbatim, so its
  # `id`/`start_url`/`scope` stay pinned to the domain root: re-root them on
  # appBasePath (identity at "/").
  postPatch = ''
    substituteInPlace apps/web/public/manifest.webmanifest \
      --replace-fail '"id": "/?source=pwa"' '"id": "${appBasePath}?source=pwa"' \
      --replace-fail '"start_url": "/dashboard"' '"start_url": "${appBasePath}dashboard"' \
      --replace-fail '"scope": "/"' '"scope": "${appBasePath}"'
  '' + lib.optionalString (appBasePath != "/") ''
    substituteInPlace apps/web/src/libs/orpc/client.ts \
      --replace-fail 'groups: [{ condition: () => true, context: {} }]' \
                     'groups: [{ condition: () => false, context: {} }]'
  '';

  nativeBuildInputs = [
    nodejs_24
    pnpm_12
    pnpmPkgs.pnpmConfigHook # reads $pnpmDeps
    autoPatchelfHook
  ];

  # Prebuilt ELF executables shipped in npm packages (esbuild, turbo) expect an
  # FHS loader the sandbox lacks; patch them before anything runs them. Only
  # executables: the shared-object .node addons are loaded by node and fine as-is.
  # (preBuild, not postConfigure: the implicit postConfigure runs BEFORE
  # pnpmConfigHook has installed node_modules.)
  dontAutoPatchelf = true;
  buildInputs = [ stdenv.cc.cc.lib ];
  preBuild = ''
    readarray -d "" elfs < <(find node_modules/.pnpm -type f -perm -0100 \
      \( -path '*/@esbuild+linux-*/bin/esbuild' -o -path '*/turbo-linux-*/bin/turbo' \) -print0)
    for f in "''${elfs[@]}"; do autoPatchelf "$f"; done
  '';

  env = {
    TURBO_TELEMETRY_DISABLED = "1";
    CI = "1";
    # Vite reads this in apps/web/vite.config.ts (`base`) at build time; the
    # patched client sources derive their router basepath + fetch bases from it.
    APP_BASE_PATH = appBasePath;
  };

  buildPhase = ''
    runHook preBuild

    # Build only the web SPA + server bundle; turbo pulls in the workspace
    # packages they depend on transitively.
    # --env-mode=loose: turbo 2.x strips undeclared env vars from tasks by
    # default (strict mode), which would hide APP_BASE_PATH from `vite build`
    # (→ base always "/"). Loose passes the full build env through to the tasks.
    pnpm exec turbo run build --filter=web --filter=server --env-mode=loose

    # Brotli copies the server sends to browsers that accept br (as the Dockerfile).
    node tooling/docker/precompress.mjs apps/web/dist

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Ship the built workspace tree wholesale: the tsdown server bundle
    # externalises npm deps, so node_modules (pnpm symlink farm, relative links
    # resolve within $out) must travel with it, alongside the web dist (+ the
    # prerendered pages) and the migrations/ folder the boot-time migrator walks
    # up to find. apps/mobile is not installed (pnpmWorkspaces), so it stays out.
    mkdir -p $out/share/reactive-resume/apps
    cp -a \
      node_modules \
      packages \
      tooling \
      plugins \
      migrations \
      package.json pnpm-lock.yaml pnpm-workspace.yaml \
      $out/share/reactive-resume/
    cp -a apps/web apps/server $out/share/reactive-resume/apps/

    mkdir -p $out/bin
    cat > $out/bin/reactive-resume <<EOF
    #!${stdenv.shell}
    exec ${nodejs_24}/bin/node $out/share/reactive-resume/apps/server/dist/index.mjs "\$@"
    EOF
    chmod +x $out/bin/reactive-resume

    # One-time v5 → v6 conversion of style-editor styles (docs: upgrading-to-v6).
    cat > $out/bin/reactive-resume-migrate-legacy-styles <<EOF
    #!${stdenv.shell}
    exec ${nodejs_24}/bin/node $out/share/reactive-resume/apps/server/dist/migrate-legacy-styles.mjs "\$@"
    EOF
    chmod +x $out/bin/reactive-resume-migrate-legacy-styles

    runHook postInstall
  '';

  # node_modules is already built for this platform; avoid fixup mangling the
  # prebuilt native addons.
  dontStrip = true;

  passthru.pnpm = pnpm_12;

  meta = {
    description = "A free and open-source resume builder (self-hosted)";
    homepage = "https://rxresu.me";
    license = lib.licenses.mit;
    mainProgram = "reactive-resume";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
})
