#!/bin/bash
#
# One-shot daemon that runs as _daemon_ to perform data migration
# between storage roots and versioned 16/main subdirectories.
#
# Direction is detected from the already-rendered Patroni YAML:
#   - YAML expects versioned (16/main)  → forward migration
#   - YAML expects root (no 16/main)    → reverse migration
set -euo pipefail

SNAP_COMMON="${SNAP_COMMON:-/var/snap/charmed-postgresql/common}"

DATA_ROOT="$SNAP_COMMON/var/lib/postgresql"
DATA_VERSIONED="$DATA_ROOT/16/main"
ARCHIVE_ROOT="$SNAP_COMMON/data/archive"
ARCHIVE_VERSIONED="$ARCHIVE_ROOT/16/main"
LOGS_ROOT="$SNAP_COMMON/data/logs"
LOGS_VERSIONED="$LOGS_ROOT/16/main"
TEMP_ROOT="$SNAP_COMMON/data/temp"
TEMP_VERSIONED="$TEMP_ROOT/16/main"

PATRONI_YAML="$SNAP_DATA/etc/patroni/patroni.yaml"
# Direct psql binary (bypasses broken Perl wrapper)
PSQL_BIN="$SNAP/usr/lib/postgresql/16/bin/psql"
LIBDIR=$(ls -d "$SNAP"/usr/lib/*-linux-gnu | head -1)
export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---- Determine direction from Patroni YAML ----
if [ ! -f "$PATRONI_YAML" ]; then
    # No YAML to guide us — create temp dir and exit
    mkdir -p "$TEMP_VERSIONED"
    exit 0
fi

# Extract operator (superuser) password from patroni.yaml.
# The charm renders this file via update_config() before snap refresh.
OPERATOR_PASSWORD=$(python3 -c "
import yaml
with open('$PATRONI_YAML') as f:
    print(yaml.safe_load(f)['postgresql']['authentication']['superuser']['password'])
")
export PGPASSWORD="$OPERATOR_PASSWORD"

if grep -q '16/main' "$PATRONI_YAML"; then
    # Target expects versioned layout (forward upgrade).
    if [ -f "$DATA_VERSIONED/PG_VERSION" ]; then
        # Already migrated — just recreate temp dir.
        mkdir -p "$TEMP_VERSIONED"
        exit 0
    fi
    if [ ! -f "$DATA_ROOT/PG_VERSION" ]; then
        # Fresh install — just create dirs.
        for path in "$DATA_VERSIONED" "$ARCHIVE_VERSIONED" "$LOGS_VERSIONED" "$TEMP_VERSIONED"; do
            mkdir -p "$path"
        done
        exit 0
    fi

    # ---- Forward migration: root -> versioned ----
    for dir in "$DATA_ROOT" "$ARCHIVE_ROOT" "$LOGS_ROOT" "$TEMP_ROOT"; do
        [ -d "$dir" ] && chmod 755 "$dir"
    done

    migrate_to_versioned() {
        local storage_root="$1"
        local versioned_path="$2"
        mkdir -p "$versioned_path"
        [ -d "$storage_root" ] || return
        for item in "$storage_root"/*; do
            [ -e "$item" ] || continue
            local name
            name=$(basename "$item")
            [ "$name" = "16" ] && continue
            [ "$name" = "lost+found" ] && continue
            [ "$name" = "pg_wal" ] && [ -L "$item" ] && continue
            local dest="$versioned_path/$name"
            [ -e "$dest" ] && continue
            mv "$item" "$dest"
        done
        chmod 700 "$versioned_path"
    }

    # Migrate persistent data directories only.  The temp tablespace is
    # ephemeral and handled by the charm via SQL DROP/CREATE TABLESPACE.
    # The temp storage root is owned by root (juju mount) so the daemon
    # running as _daemon_ cannot rename files inside it.
    migrate_to_versioned "$LOGS_ROOT"    "$LOGS_VERSIONED"
    migrate_to_versioned "$DATA_ROOT"    "$DATA_VERSIONED"
    migrate_to_versioned "$ARCHIVE_ROOT" "$ARCHIVE_VERSIONED"
    mkdir -p "$TEMP_VERSIONED"

    # Repair pg_wal symlink
    PG_WAL_LINK="$DATA_VERSIONED/pg_wal"
    if [ -L "$PG_WAL_LINK" ]; then
        CURRENT_TARGET=$(readlink -f "$PG_WAL_LINK")
        if [ "$CURRENT_TARGET" != "$LOGS_VERSIONED" ]; then
            unlink "$PG_WAL_LINK"
            ln -s "$LOGS_VERSIONED" "$PG_WAL_LINK"
        fi
    elif [ ! -e "$PG_WAL_LINK" ]; then
        ln -s "$LOGS_VERSIONED" "$PG_WAL_LINK"
    fi
else
    # Target expects root layout (rollback).
    #
    # ---- Reverse migration for temp tablespace catalog ----
    # Run BEFORE the data-migration early-exit guard so that the
    # catalog is always reconciled, even if persistent data was
    # already moved back to root on a previous cycle.
    CURRENT_LOCATION=$(PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -tAc \
        "SELECT pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname='temp';")

    if [ "$CURRENT_LOCATION" = "$TEMP_VERSIONED" ]; then
        PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "DROP TABLESPACE temp;"
        PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "CREATE TABLESPACE temp LOCATION '$TEMP_ROOT';"
        PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "GRANT CREATE ON TABLESPACE temp TO public;"
    fi

    if [ ! -f "$DATA_VERSIONED/PG_VERSION" ]; then
        # Data already at root — nothing to do.
        mkdir -p "$TEMP_VERSIONED"
        exit 0
    fi

    # ---- Reverse migration: versioned -> root ----
    for dir in "$DATA_ROOT" "$ARCHIVE_ROOT" "$LOGS_ROOT"; do
        [ -d "$dir" ] && chmod 755 "$dir"
    done
    # Ensure parent dirs of versioned paths are writable.
    # Temp is excluded — subdirs inside it may be root-owned (created by
    # the charm running as root).  An ephemeral mount chowned by the charm.
    for p in "$DATA_VERSIONED" "$ARCHIVE_VERSIONED" "$LOGS_VERSIONED"; do
        [ -d "$p" ] && chmod 755 "$p"
        [ -d "$(dirname "$p")" ] && chmod 755 "$(dirname "$p")"
    done

    if [ -L "$DATA_VERSIONED/pg_wal" ]; then
        unlink "$DATA_VERSIONED/pg_wal"
    fi

    # Reverse migration: move versioned contents back to storage roots.
    reverse_one() {
        local versioned="$1"
        local root="$2"
        [ -d "$versioned" ] || return
        for item in "$versioned"/*; do
            [ -e "$item" ] || continue
            mv "$item" "$root/"
        done
        rmdir "$versioned"
        rmdir "$(dirname "$versioned")"
    }

    reverse_one "$DATA_VERSIONED"    "$DATA_ROOT"
    reverse_one "$ARCHIVE_VERSIONED" "$ARCHIVE_ROOT"
    reverse_one "$LOGS_VERSIONED"    "$LOGS_ROOT"
    # Temp tablespace is handled by the charm.  Clean up versioned dir if present.
    rmdir "$TEMP_VERSIONED"
    rmdir "$(dirname "$TEMP_VERSIONED")"

    # PostgreSQL requires mode 700 on the data directory.
    # Do this before recreating pg_wal to avoid a window with wrong perms.
    [ -d "$DATA_ROOT" ] && chmod 700 "$DATA_ROOT"

    # Recreate pg_wal symlink at root — removed from versioned path earlier.
    if [ ! -e "$DATA_ROOT/pg_wal" ]; then
        ln -s "$LOGS_ROOT" "$DATA_ROOT/pg_wal"
    fi
fi

# Relax storage root permissions for confined hooks.
for dir in "$ARCHIVE_ROOT" "$LOGS_ROOT" "$TEMP_ROOT"; do
    [ -d "$dir" ] && chmod 755 "$dir"
done
