#!/usr/bin/env bash
# Recompute Reactive Resume's Nix hashes after Renovate bumps `version`.
#
# Renovate's customManager rewrites `version = "X.Y.Z"` (the reactive-resume pin,
# anchored on pname — NOT the pnpm_11 pin), then runs this as a postUpgradeTask
# (arg $1 = new version). package.nix has THREE `hash = "sha256-…"` literals (the
# pnpm_11 tarball, the src, and pnpmDeps), so every substitution is value-based to
# avoid clobbering the wrong one. Two hashes change on an upstream bump:
#   1. src hash    — fetchFromGitHub amruthpillai/Reactive-Resume (via nurl)
#   2. pnpmDeps    — fetchPnpmDeps FOD (built in isolation, got: captured)
# Requires nurl + nix on PATH (the CI workflow installs them).
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
  ver=$(sed -n '/pname = "reactive-resume";/,/version = "/p' package.nix \
          | grep -oE 'version = "[^"]+"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
echo ">> recomputing hashes for reactive-resume v$ver"

# 1. src hash — replace the OLD value (from the fetchFromGitHub block only) with
# the nurl-computed new one, so the pnpm_11 tarball hash + pnpmDeps hash are safe.
# SKIP_SRC_HASH=1 on the arm64 leg: the x86_64 leg already wrote it.
if [ "${SKIP_SRC_HASH:-0}" = 1 ]; then
  echo ">> src hash   = skipped (SKIP_SRC_HASH=1)"
else
  newsrc=$(nurl "https://github.com/amruthpillai/Reactive-Resume" "v$ver" 2>/dev/null \
             | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  [ -n "$newsrc" ] || { echo "ERROR: nurl returned no src hash for v$ver"; exit 1; }
  oldsrc=$(sed -n '/src = fetchFromGitHub {/,/};/p' package.nix \
             | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  [ -n "$oldsrc" ] || { echo "ERROR: could not locate current src hash"; exit 1; }
  [ "$oldsrc" = "$newsrc" ] || sed -i "s#$oldsrc#$newsrc#" package.nix
  echo ">> src hash   = $newsrc"
fi

# 2. pnpmDeps FOD — per-system, so only this system's slot is rewritten: the two
# slots can hold the same stale value, and a value-based sed would clobber both.
# The hash also depends on the nixpkgs the fetcher comes from: nic-os builds with
# its own pin (follows), whose aarch64 hash differs from this flake's unstable.
# NIXPKGS_REV computes against that pin instead.
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
echo ">> system     = $system"
override=()
if [ -n "${NIXPKGS_REV:-}" ]; then
  override=(--override-input nixpkgs "github:NixOS/nixpkgs/$NIXPKGS_REV")
  echo ">> nixpkgs    = $NIXPKGS_REV (override)"
fi
out=$(nix build ".#reactive-resume.pnpmDeps" "${override[@]}" --no-link 2>&1) || true
if printf '%s\n' "$out" | grep -q 'hash mismatch'; then
  got=$(printf '%s\n' "$out" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  [ -n "$got" ] || { printf '%s\n' "$out"; echo "ERROR: pnpmDeps mismatch without a got: hash"; exit 1; }
  n=$(grep -cE "^[[:space:]]+$system = \"sha256-" package.nix)
  [ "$n" = 1 ] || { echo "ERROR: expected 1 pnpmDeps slot for $system, found $n"; exit 1; }
  sed -i -E "s#^([[:space:]]+$system = \")sha256-[A-Za-z0-9+/=]+#\1$got#" package.nix
  echo ">> pnpmDeps   = $got (updated for $system)"
  nix build ".#reactive-resume.pnpmDeps" "${override[@]}" --no-link >/dev/null # confirm it resolves
elif printf '%s\n' "$out" | grep -qE '^/nix/store/'; then
  echo ">> pnpmDeps   unchanged for $system"
else
  printf '%s\n' "$out"; echo "ERROR: pnpmDeps build failed for a reason other than a hash mismatch"; exit 1
fi

echo ">> hash recompute complete for reactive-resume v$ver"
