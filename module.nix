# NixOS module for Reactive Resume — self-hosted resume builder (rxresu.me).
#
# Usage in nic-os (or any NixOS flake):
#
#   inputs.reactive-resume-nix.url = "github:nSimonFR/reactive-resume-nix";
#
#   imports = [ inputs.reactive-resume-nix.nixosModules.reactive-resume ];
#   services.reactive-resume = {
#     enable          = true;
#     appUrl          = "https://resume.example.ts.net";
#     environmentFile = "/run/agenix/reactive-resume-env";  # DATABASE_URL + AUTH_SECRET
#   };
#
# The environmentFile must export at minimum:
#   DATABASE_URL=postgresql://reactive_resume:<password>@127.0.0.1:5432/reactive_resume
#   AUTH_SECRET=<32+ byte secret>
#
# Reactive Resume v5 is a single Node (Hono) process serving the built Vite SPA
# plus the REST/oRPC API. It uses Drizzle ORM with raw-SQL migrations that the
# server SELF-APPLIES on boot (apps/server/src/startup/checks.ts, walking up to
# migrations/), so there is no separate migrate oneshot — the app just needs a
# reachable PostgreSQL database. PostgreSQL must be provided by the host.
#
# This module ships the plain always-on service. To make it sleep when idle
# (recommended on memory-constrained hosts), wrap it with a socket-activation
# proxy on the host side — the module changes nothing to support that beyond
# leaving `host`/`port` configurable.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.reactive-resume;
  defaultPackage = pkgs.callPackage (self + "/package.nix") { };

  appEnv = {
    NODE_ENV = "production";
    HOST = cfg.host;
    PORT = toString cfg.port;
    APP_URL = cfg.appUrl;
    LOCAL_STORAGE_PATH = cfg.storagePath;
  } // cfg.settings;
in
{
  options.services.reactive-resume = {
    enable = lib.mkEnableOption "Reactive Resume self-hosted resume builder";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "The Reactive Resume derivation to use.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Node server binds to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the Node server listens on.";
    };

    appUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://resume.example.ts.net";
      description = ''
        Public origin (scheme://host[:port]) the app is served from → APP_URL.
        Used for absolute links and auth callbacks.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/reactive-resume";
      description = "Persistent state directory (parent of storagePath).";
    };

    storagePath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/data";
      defaultText = lib.literalExpression ''"''${cfg.stateDir}/data"'';
      description = "Local-disk artifact storage → LOCAL_STORAGE_PATH (no S3).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file exporting secrets as KEY=VALUE lines. Supply DATABASE_URL
        (with password) and AUTH_SECRET here so they stay out of the
        world-readable Nix store.
      '';
    };

    user = lib.mkOption { type = lib.types.str; default = "reactive-resume"; };
    group = lib.mkOption { type = lib.types.str; default = "reactive-resume"; };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "systemd MemoryMax= cap for the service.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        FLAG_DISABLE_SIGNUPS = "true";
        NODE_OPTIONS = "--max-old-space-size=384";
      };
      description = ''
        Extra environment variables merged into the service (FLAG_* feature
        flags, NODE_OPTIONS heap tuning, MALLOC_ARENA_MAX, …).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = lib.mkIf (cfg.user == "reactive-resume") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
    };
    users.groups.${cfg.group} = lib.mkIf (cfg.group == "reactive-resume") { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}    0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.storagePath} 0750 ${cfg.user} ${cfg.group} -"
    ];

    # ── reactive-resume: Hono server (serves the Vite SPA + API) ─────────────
    # Migrations self-apply on boot, so no migrate oneshot; the app just needs a
    # reachable DB (DATABASE_URL from environmentFile).
    systemd.services.reactive-resume = {
      description = "Reactive Resume — resume builder";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = appEnv;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "${cfg.package}/share/reactive-resume"; # migrator walks up → migrations/
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "5s";
        MemoryMax = cfg.memoryMax;

        # Some hosts (RPi5) have no user namespaces; the nixpkgs default
        # PrivateUsers=true fails there. Leave it off — hosts that want it can
        # override.
        PrivateUsers = lib.mkForce false;

        # Hardening: needs network + its own state dir; sandbox the rest.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        LockPersonality = true;
        RestrictRealtime = true;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
