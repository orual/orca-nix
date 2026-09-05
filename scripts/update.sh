#!/usr/bin/env bash
set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly GITHUB_REPO="sjennings/orca"
readonly PACKAGE_FILE="package.nix"
readonly PNPM_HASH_PLACEHOLDER="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

BACKUP_FILE=""
UPDATE_SUCCEEDED=false

log_info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2; }

flake_ref() {
    printf 'path:%s#orca\n' "$(pwd -P)"
}

pnpm_deps_ref() {
    printf '%s.pnpmDeps\n' "$(flake_ref)"
}

get_current_revision() {
    sed -n 's/.*sourceRev = "\([^"]*\)".*/\1/p' "$PACKAGE_FILE" | head -1
}

ensure_in_repository_root() {
    if [[ ! -f flake.nix || ! -f $PACKAGE_FILE ]]; then
        log_error "flake.nix or $PACKAGE_FILE not found. Run this script from the repository root."
        exit 1
    fi
}

ensure_required_tools_installed() {
    local tool
    for tool in curl gh grep jq nix nix-prefetch-url perl sed tar git; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "$tool is required but not installed."
            exit 1
        fi
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Resolve a fork ref to a full commit, update package.nix, refresh its source and
pnpm dependency hashes, then build and CLI-check the package. package.nix is
restored if any update step fails, and flake.lock is never touched.

Options:
  --rev REV   Commit, branch, or tag in $GITHUB_REPO (default: main)
  --check     Only check whether the selected ref differs from sourceRev
  --help      Show this help message
EOF
}

parse_arguments() {
    REV_REQUEST="main"
    CHECK_ONLY=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rev)
                if [[ $# -lt 2 ]]; then
                    log_error "--rev requires a value"
                    print_usage
                    exit 1
                fi
                REV_REQUEST="$2"
                shift 2
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

resolve_revision() {
    local requested="$1"
    local revision

    revision=$(gh api "repos/$GITHUB_REPO/commits/$requested" --jq '.sha' 2>/dev/null || true)
    if [[ ! $revision =~ ^[0-9a-fA-F]{40}$ ]]; then
        log_error "Could not resolve '$requested' to a full commit in $GITHUB_REPO"
        exit 1
    fi

    printf '%s\n' "${revision,,}"
}

get_source_version() {
    local revision="$1"
    local archive_dir
    local archive
    local package_json_path
    local version

    archive_dir=$(mktemp -d)
    archive="$archive_dir/source.tar.gz"
    if ! curl -fsSL --retry 3 -o "$archive" "https://github.com/$GITHUB_REPO/archive/$revision.tar.gz"; then
        rm -rf "$archive_dir"
        log_error "Failed to download source archive for $revision"
        exit 1
    fi

    package_json_path=$(tar -tzf "$archive" | sed -n 's|^\([^/]\+\)/package.json$|\1/package.json|p' | tail -n 1)
    if [[ -z $package_json_path ]]; then
        rm -rf "$archive_dir"
        log_error "Source archive for $revision has no root package.json"
        exit 1
    fi

    if ! version=$(tar -xOf "$archive" "$package_json_path" | jq -er '.version'); then
        rm -rf "$archive_dir"
        log_error "Could not read version from $package_json_path"
        exit 1
    fi
    rm -rf "$archive_dir"

    if [[ ! $version =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; then
        log_error "Invalid package version from source package.json: $version"
        exit 1
    fi
    printf '%s\n' "$version"
}

get_source_hash() {
    local revision="$1"
    local source_url="https://github.com/$GITHUB_REPO/archive/$revision.tar.gz"
    local nix32_hash

    # --unpack matches fetchFromGitHub's normalized (stripped source) hash.
    if ! nix32_hash=$(nix-prefetch-url --unpack --type sha256 "$source_url"); then
        log_error "Failed to prefetch normalized source for $revision"
        exit 1
    fi
    nix hash convert --hash-algo sha256 --from nix32 --to sri "$nix32_hash"
}

update_version() {
    local version="$1"
    perl -0pi -e "s/version = \"[^\"]+\";/version = \"$version\";/" "$PACKAGE_FILE"
}

update_source_revision() {
    local revision="$1"
    perl -0pi -e "s/sourceRev = \"[^\"]+\";/sourceRev = \"$revision\";/" "$PACKAGE_FILE"
}

update_source_hash() {
    local hash="$1"
    perl -0pi -e "s|(src = fetchFromGitHub \\{.*?hash = )\"[^\"]+\";|\${1}\"$hash\";|s" "$PACKAGE_FILE"
}

update_pnpm_hash() {
    local hash="$1"
    perl -0pi -e "s|(pnpmDeps = fetchPnpmDeps \\{.*?hash = )\"[^\"]+\";|\${1}\"$hash\";|s" "$PACKAGE_FILE"
}

get_pnpm_deps_hash() {
    local build_output
    local build_status
    local hash

    # A deliberately invalid hash makes Nix calculate the exact fixed-output
    # hash. Build the passthru explicitly so the full package is not rebuilt.
    update_pnpm_hash "$PNPM_HASH_PLACEHOLDER"
    set +e
    build_output=$(nix build "$(pnpm_deps_ref)" --no-link --print-build-logs 2>&1)
    build_status=$?
    set -e

    if [[ $build_status -eq 0 ]]; then
        log_error "pnpmDeps unexpectedly built with the placeholder hash"
        exit 1
    fi

    hash=$(printf '%s\n' "$build_output" | sed -nE 's/.*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+).*/\1/p' | tail -n 1)
    if [[ -z $hash || $hash == "$PNPM_HASH_PLACEHOLDER" ]]; then
        printf '%s\n' "$build_output" >&2
        log_error "Could not extract the pnpmDeps fixed-output hash"
        exit 1
    fi
    printf '%s\n' "$hash"
}

verify_update() {
    local help_output

    log_info "Building Orca"
    nix build "$(flake_ref)" --print-build-logs

    log_info "Checking Orca CLI"
    help_output=$(./result/bin/orca --help)
    grep -q 'Usage: orca' <<< "$help_output"

    log_info "Verifying package contents"
    test -x ./result/bin/orca
    test -x ./result/bin/orca-ide
}

rollback_update() {
    local status=$?
    trap - EXIT
    if [[ $UPDATE_SUCCEEDED != true && -n $BACKUP_FILE && -f $BACKUP_FILE ]]; then
        log_warn "Update failed; restoring $PACKAGE_FILE"
        cp "$BACKUP_FILE" "$PACKAGE_FILE" || status=1
    fi
    if [[ -n $BACKUP_FILE ]]; then
        rm -f "$BACKUP_FILE" || status=1
    fi
    return "$status"
}

show_changes() {
    echo ""
    log_info "Changes made (package.nix only):"
    git diff --stat -- "$PACKAGE_FILE" 2>/dev/null || true
}

update_to_revision() {
    local current_revision="$1"
    local revision="$2"
    local source_version
    local source_hash
    local pnpm_hash

    BACKUP_FILE="$PACKAGE_FILE.bak"
    UPDATE_SUCCEEDED=false
    cp "$PACKAGE_FILE" "$BACKUP_FILE"
    trap rollback_update EXIT

    log_info "Updating Orca from $current_revision to $revision"
    source_version=$(get_source_version "$revision")
    log_info "Source package.json version: $source_version"
    source_hash=$(get_source_hash "$revision")
    log_info "Updating normalized fetchFromGitHub source hash"
    update_source_revision "$revision"
    update_version "$source_version"
    update_source_hash "$source_hash"

    log_info "Refreshing pnpmDeps hash with explicit $(pnpm_deps_ref) target"
    pnpm_hash=$(get_pnpm_deps_hash)
    update_pnpm_hash "$pnpm_hash"

    # Do not accept the update until both the package build and CLI smoke test
    # have passed. flake.lock is intentionally not touched by this updater.
    verify_update

    rm -f "$BACKUP_FILE"
    BACKUP_FILE=""
    UPDATE_SUCCEEDED=true
    trap - EXIT
    show_changes
}

main() {
    parse_arguments "$@"
    ensure_in_repository_root
    ensure_required_tools_installed

    local current_revision
    local selected_revision
    current_revision=$(get_current_revision)
    selected_revision=$(resolve_revision "$REV_REQUEST")

    log_info "Current revision: $current_revision"
    log_info "Selected revision: $selected_revision"

    if [[ $current_revision == "$selected_revision" ]]; then
        log_info "Already up to date"
        exit 0
    fi

    if [[ $CHECK_ONLY == true ]]; then
        log_info "Update available: $current_revision -> $selected_revision"
        exit 1
    fi

    update_to_revision "$current_revision" "$selected_revision"
}

main "$@"
