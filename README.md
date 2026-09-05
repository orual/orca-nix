# orca-nix

Nix package for the [sjennings fork of Orca](https://github.com/sjennings/orca), the ADE for working with a fleet of parallel agents.

This flake builds Orca from pinned source using a packaged Electron runtime, rather than wrapping upstream AppImage releases. It exposes two commands:

- `orca-ide`: desktop app launcher
- `orca`: headless and automation CLI

## Quick Start

Launch the desktop app:

```bash
nix run github:kevinpita/orca-nix
```

Run the CLI:

```bash
nix run github:kevinpita/orca-nix#orca -- --help
nix run github:kevinpita/orca-nix#orca -- serve
```

## Install

```bash
nix profile install github:kevinpita/orca-nix
orca --help
orca-ide
```

## Binary Cache

The flake advertises the existing `kevinpita` [Cachix](https://www.cachix.org/) cache via `nixConfig`. Fork builds may not be available there; a cache miss builds Orca locally. The first `nix run` or `nix profile install` will ask to trust the cache. To opt in permanently:

```bash
cachix use kevinpita
```

## Use In A Flake

Add `github:kevinpita/orca-nix` as an input, then use `orca-nix.packages.${system}.default` wherever you build your package list.

## Development

```bash
nix build .#orca
./result/bin/orca --help
./result/bin/orca-ide
```

The source package is built and CLI-smoke-tested on `x86_64-linux`. `aarch64-linux` is exposed and evaluates, but has not been build-tested.

The pinned toolchain uses Node 24, Electron 43, and nixpkgs' pnpm 11. Upstream declares pnpm 12; the Nix dependency hook uses its lockfile-compatibility settings to install the pinned v9 lockfile with pnpm 11. Orca and its patched `node-pty` addon are compiled locally; Electron comes from nixpkgs. The Linux glibc compatibility check targets the Nix runtime rather than upstream's Ubuntu 20.04 baseline.

## Updates

The update workflow checks `sjennings/orca` commits hourly and can also be run manually from GitHub Actions. Updates pin a fork revision in `package.nix`, refresh its source and dependency hashes, and build and check the CLI before creating a pull request. Nixpkgs and the other flake inputs stay pinned; update those separately with `nix flake update`.

Manual update:

```bash
./scripts/update.sh --check
./scripts/update.sh --rev main
```
