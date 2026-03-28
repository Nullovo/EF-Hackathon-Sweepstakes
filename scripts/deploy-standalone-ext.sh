#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"

setup

ENV=$(get_env "${1:-}")
PKG_DIR="${2:-}"
OUT_FILE="${3:-}"
DISPLAY_NAME="${4:-Standalone extension}"

if [[ -z "$PKG_DIR" || -z "$OUT_FILE" ]]; then
    echo "Usage: $0 [network] <package-dir> <output-file> <display-name>" >&2
    exit 1
fi

WORLD_DEP_PUBLISHED_AT="${WORLD_PACKAGE_ID:-0xd12a70c74c1e759445d6f209b01d43d860e97fcf2ef72ccbbd00afd828043f75}"
ASSETS_DEP_PUBLISHED_AT="${ASSETS_PACKAGE_ID:-0xf0446b93345c1118f21239d7ac58fb82d005219b2016e100f074e4d17162a465}"

set_package_published_at() {
    local file_path="$1"
    local published_at="$2"
    local tmp_file
    tmp_file="$(mktemp)"

    awk -v published_at="$published_at" '
        BEGIN {
            in_package = 0
            inserted = 0
        }
        /^\[package\]$/ {
            in_package = 1
            print
            next
        }
        in_package && /^published-at[[:space:]]*=/ {
            print "published-at = \"" published_at "\""
            inserted = 1
            next
        }
        in_package && /^\[/ {
            if (!inserted) {
                print "published-at = \"" published_at "\""
                inserted = 1
            }
            in_package = 0
            print
            next
        }
        {
            print
        }
        END {
            if (in_package && !inserted) {
                print "published-at = \"" published_at "\""
            }
        }
    ' "$file_path" > "$tmp_file"

    mv "$tmp_file" "$file_path"
}

set_named_address_value() {
    local file_path="$1"
    local address_name="$2"
    local address_value="$3"
    local tmp_file
    tmp_file="$(mktemp)"

    awk -v address_name="$address_name" -v address_value="$address_value" '
        BEGIN {
            in_addresses = 0
            inserted = 0
        }
        /^\[addresses\]$/ {
            in_addresses = 1
            print
            next
        }
        in_addresses && $0 ~ ("^" address_name "[[:space:]]*=") {
            print address_name " = \"" address_value "\""
            inserted = 1
            next
        }
        in_addresses && /^\[/ {
            if (!inserted) {
                print address_name " = \"" address_value "\""
                inserted = 1
            }
            in_addresses = 0
            print
            next
        }
        {
            print
        }
        END {
            if (in_addresses && !inserted) {
                print address_name " = \"" address_value "\""
            }
        }
    ' "$file_path" > "$tmp_file"

    mv "$tmp_file" "$file_path"
}

if [[ "$ENV" != "localnet" ]]; then
    WORLD_MOVE_BACKUP="$(mktemp)"
    ASSETS_MOVE_BACKUP="$(mktemp)"
    TARGET_MOVE_BACKUP="$(mktemp)"

    cp contracts/world/Move.toml "$WORLD_MOVE_BACKUP"
    cp contracts/assets/Move.toml "$ASSETS_MOVE_BACKUP"
    cp "contracts/$PKG_DIR/Move.toml" "$TARGET_MOVE_BACKUP"

    restore_dependency_manifests() {
        cp "$WORLD_MOVE_BACKUP" contracts/world/Move.toml
        cp "$ASSETS_MOVE_BACKUP" contracts/assets/Move.toml
        cp "$TARGET_MOVE_BACKUP" "contracts/$PKG_DIR/Move.toml"
        rm -f "$WORLD_MOVE_BACKUP" "$ASSETS_MOVE_BACKUP" "$TARGET_MOVE_BACKUP"
    }

    trap restore_dependency_manifests EXIT

    set_package_published_at contracts/world/Move.toml "$WORLD_DEP_PUBLISHED_AT"
    set_package_published_at contracts/assets/Move.toml "$ASSETS_DEP_PUBLISHED_AT"
    set_named_address_value contracts/world/Move.toml "world" "$WORLD_DEP_PUBLISHED_AT"
    set_named_address_value contracts/assets/Move.toml "assets" "$ASSETS_DEP_PUBLISHED_AT"
    set_named_address_value "contracts/$PKG_DIR/Move.toml" "extension_examples" "0x0"
fi

rm -rf "contracts/$PKG_DIR/Published.toml" "contracts/$PKG_DIR/Pub.*.toml"
mkdir -p "deployments/$ENV"

start_logging "$ENV" "deploy-$PKG_DIR"

echo "--- $(package_manager_name) install ---"
package_manager_install

echo "--- sui client publish ---"
publish "$PKG_DIR" "deployments/$ENV/$OUT_FILE" "$ENV" "../world/Pub.localnet.toml"

echo "Deployed $DISPLAY_NAME to $ENV. Output: deployments/$ENV/$OUT_FILE"
echo "Log: deployments/$ENV/deploy.log"
