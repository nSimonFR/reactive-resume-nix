# reactive-resume-nix

Nix flake packaging [Reactive Resume](https://github.com/amruthpillai/Reactive-Resume) (rxresu.me) — a free, open-source, self-hosted resume builder — as a native NixOS service (no Docker).

Provides:
- `packages.reactive-resume` — the v5 app built from source (pnpm 11 + turbo monorepo: Vite SPA + Hono server bundle)
- `nixosModules.reactive-resume` — a NixOS module configuring the single always-on Node service
- `overlays.default` — exposes `pkgs.reactive-resume`

## AI Installation Prompt

> **This repo is the Nix packaging for Reactive Resume.** If your host is not running Nix or NixOS, install Reactive Resume from its [upstream](https://github.com/amruthpillai/Reactive-Resume) directly; this flake won't help you.
>
> Install Reactive Resume via this flake on a Nix-capable host. **Done when** the web UI loads on the configured port and you can sign in.
>
> 1. Clone: `git clone https://github.com/nSimonFR/reactive-resume-nix && cd reactive-resume-nix`
> 2. Read first: `flake.nix`, `package.nix`, `module.nix`, `README.md`. Toolchain is Nix flakes + Node 24 + pnpm 11.10.0 (all handled inside the derivation; you don't install them yourself).
> 3. Build the derivation only (sanity check): `nix build`. The first build fetches the whole pnpm store as a fixed-output derivation (~1400 deps, uncached ~20 min).
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
| `appUrl` | — | Public origin → `APP_URL` (required) |
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

There is intentionally no migrate oneshot (the server does it) and no Redis/S3 dependency in the default footprint.

## Updating Reactive Resume

The build pins three hashes in `package.nix` that must be bumped together on a version change:

1. Set `version` to the new upstream tag.
2. Update the source `hash` (`fetchFromGitHub`) — build once and copy the "got:" hash.
3. Update the `pnpmDeps` `hash` (`fetchPnpmDeps`) — same, from the deps FOD failure.

Commit `package.nix`.

## License

MIT (upstream Reactive Resume license).
