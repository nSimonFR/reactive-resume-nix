# reactive-resume-nix

Nix flake packaging [Reactive Resume](https://github.com/amruthpillai/Reactive-Resume) (rxresu.me) — a free, open-source, self-hosted resume builder — as a native NixOS service (no Docker).

Provides:
- `packages.reactive-resume` — the v6 app built from source (pnpm 12 + turbo monorepo: Vite SPA + prerendered marketing pages + Hono server bundle; PDFs render in-process with Forme/WASM, no Chromium)
- `nixosModules.reactive-resume` — a NixOS module configuring the single always-on Node service
- `overlays.default` — exposes `pkgs.reactive-resume`

## AI Installation Prompt

> **This repo is the Nix packaging for Reactive Resume.** If your host is not running Nix or NixOS, install Reactive Resume from its [upstream](https://github.com/amruthpillai/Reactive-Resume) directly; this flake won't help you.
>
> Install Reactive Resume via this flake on a Nix-capable host. **Done when** the web UI loads on the configured port and you can sign in.
>
> 1. Clone: `git clone https://github.com/nSimonFR/reactive-resume-nix && cd reactive-resume-nix`
> 2. Read first: `flake.nix`, `package.nix`, `module.nix`, `README.md`. Toolchain is Nix flakes + Node 24 + pnpm 12 (prebuilt binary, `pnpm.nix`) (all handled inside the derivation; you don't install them yourself).
> 3. Build the derivation only (sanity check): `nix build`. The first build fetches the whole pnpm store as a fixed-output derivation (web + server + tooling projects only; the Expo mobile app is skipped).
> 4. Deploy as a NixOS service:
>    - Add this flake to your system flake inputs (`reactive-resume-nix.url = "github:nSimonFR/reactive-resume-nix";`).
>    - Import `inputs.reactive-resume-nix.nixosModules.reactive-resume`.
>    - Configure `services.reactive-resume = { enable = true; port = <p>; appUrl = "https://<host>"; environmentFile = "<path>"; };`
> 5. Provide PostgreSQL on the same host (or reachable). The `environmentFile` must define `DATABASE_URL` and `AUTH_SECRET` — see `module.nix`.
> 6. `sudo nixos-rebuild switch --flake .#<host>`. Open the configured port.
>
> **The server self-applies its DB migrations on boot** by walking parent dirs from `apps/server/dist` to find `migrations/`, so that folder MUST stay at the package root (`share/reactive-resume/migrations`) — `package.nix` already ships it. There is no separate migrate step.

## Usage

### Standalone build

```bash
nix build github:nSimonFR/reactive-resume-nix
```

### NixOS module

```nix
# flake.nix
inputs.reactive-resume-nix.url = "github:nSimonFR/reactive-resume-nix";

# configuration.nix
imports = [ inputs.reactive-resume-nix.nixosModules.reactive-resume ];

services.reactive-resume = {
  enable          = true;
  port            = 3000;
  appUrl          = "https://resume.example.ts.net";
  environmentFile = "/run/secrets/reactive-resume-env";
  # Pi-friendly footprint: no image processing, closed signups, small heap.
  settings = {
    FLAG_DISABLE_IMAGE_PROCESSING = "true";
    FLAG_DISABLE_SIGNUPS          = "true";
    NODE_OPTIONS                  = "--max-old-space-size=384";
  };
};
```

The `environmentFile` must export at minimum:
```
DATABASE_URL=postgresql://reactive_resume:<password>@127.0.0.1:5432/reactive_resume
AUTH_SECRET=<32+ byte secret>
```

### Module options

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable Reactive Resume |
| `package` | flake default | Override the derivation |
| `host` | `127.0.0.1` | Address the Node server binds to |
| `port` | `3000` | HTTP listen port |
| `appUrl` | — | Public URL → `APP_URL` (required; include the sub-path when `appBasePath` is set) |
| `appBasePath` | `/` | Build the SPA for a URL sub-path (e.g. `/rxresume/`); applies `patches/base-path-support.patch` |
| `stateDir` | `/var/lib/reactive-resume` | Persistent state directory |
| `storagePath` | `${stateDir}/data` | Local artifact storage → `LOCAL_STORAGE_PATH` |
| `environmentFile` | `null` | Path to a `KEY=VALUE` secrets file (`DATABASE_URL`, `AUTH_SECRET`) |
| `user` / `group` | `reactive-resume` | Service user/group |
| `memoryMax` | `512M` | systemd `MemoryMax=` |
| `settings` | `{}` | Extra env vars (`FLAG_*`, `NODE_OPTIONS`, …) |

## Systemd services

| Unit | Type | Description |
|---|---|---|
| `reactive-resume.service` | simple | Hono server; serves the SPA + API and self-applies migrations on boot |

There is intentionally no migrate oneshot (the server does it) and no Redis/S3 dependency in the default footprint. Optional v6 settings (all via `settings`/`environmentFile`): `REDIS_URL` (assistant stream resume, shared limits), `ENCRYPTION_SECRET` (required for AI providers/assistant), `TRUSTED_PROXIES` (behind a reverse proxy), `AI_*`, `WEB_ACCESS_*`, `STRICT_SCHEMA_CHECK`. The built-in MCP server is at `<APP_URL>/mcp` (`x-api-key` or OAuth; OAuth needs a root-served install).

Upgrading from v5: back up the database first — the v6 migrations drop columns v5 reads, so v5 cannot run against a migrated database. Old style-editor styles convert with `reactive-resume-migrate-legacy-styles` (dry run by default; `--apply --backup <file>`).

## Updating Reactive Resume

The build pins three hashes in `package.nix` that must be bumped together on a version change:

1. Set `version` to the new upstream tag.
2. Update the source `hash` (`fetchFromGitHub`) — build once and copy the "got:" hash.
3. Update the `pnpmDeps` hash for **each** system (`x86_64-linux`, `aarch64-linux`): the store differs per arch. `ci/renovate-update.sh` rewrites the slot of the system it runs on; Renovate covers x86_64, run it on an aarch64 host for the other.
4. If `package.json` `packageManager` moved, bump `pnpm.nix` (version + both binary hashes).
5. If `patches/base-path-support.patch` stops applying, re-port it on the new tag (`git diff` of the edited tree).

Commit `package.nix`.

## License

MIT (upstream Reactive Resume license).
