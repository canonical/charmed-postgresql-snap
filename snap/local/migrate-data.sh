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
LIBDIR=$(ls -d "$SNAP"/usr/lib/*-linux-gnu 2>/dev/null | head -1)
export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Extract operator (superuser) password from patroni.yaml.
# The charm renders this file via update_config() before snap refresh.
if [ -z "${SNAP:-}" ]; then
    echo "SNAP not set — cannot extract operator password" >&2
else
OPERATOR_PASSWORD=$(python3 -c "
import yaml
with open('$SNAP_DATA/etc/patroni/patroni.yaml') as f:
    print(yaml.safe_load(f)['postgresql']['authentication']['superuser']['password'])
" 2>/dev/null || true)
export PGPASSWORD="$OPERATOR_PASSWORD"
fi

# ---- Determine direction from Patroni YAML ----
if [ ! -f "$PATRONI_YAML" ]; then
    # No YAML to guide us — create temp dir and exit
    mkdir -p "$TEMP_VERSIONED"
    exit 0
fi

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
    # Must run BEFORE file migration so PostgreSQL can replay WAL
    # without referencing stale versioned temp directories.
    CURRENT_LOCATION=$(PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -tAc \
        "SELECT pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname='temp';" 2>/dev/null || true)

    if [ "$CURRENT_LOCATION" = "$TEMP_VERSIONED" ]; then
        # Only the primary can execute DDL.  Replicas skip this block;
        # the primary's pre-refresh hook handles the catalog migration.
        IS_RECOVERY=$(PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -tAc \
            "SELECT pg_is_in_recovery();" 2>/dev/null || true)
        if [ "$IS_RECOVERY" != "t" ]; then
            if [ -d "$TEMP_ROOT" ]; then
                find "$TEMP_ROOT" -maxdepth 1 -name 'PG_*' -exec rm -rf {} +
            fi
            PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "DROP TABLESPACE temp;"
            PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "CREATE TABLESPACE temp LOCATION '$TEMP_ROOT';"
            PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "GRANT CREATE ON TABLESPACE temp TO public;"
            # Flush WAL so recovery after rollback won't replay stale
            # Tablespace/CREATE records pointing to the versioned path.
            PGPASSWORD="$OPERATOR_PASSWORD" "$PSQL_BIN" -h /tmp -U operator -d postgres -c "CHECKPOINT;"
        fi
    fi

    # Stop Patroni before relocating the data directory. snapd stops the snap's
    # daemons only AFTER this pre-refresh hook, so Patroni is still live here;
    # the moment we move files out of 16/main below, its HA loop restarts
    # PostgreSQL and rewrites pg_hba.conf/pg_ident.conf/standby.signal back into
    # 16/main, making `rmdir 16/main` fail "Directory not empty" and aborting the
    # rollback under `set -e`. Must be a service-level stop (the service is
    # restart-condition=always, so a kill would be revived by systemd); the charm
    # restarts Patroni afterwards in _post_snap_refresh(). `timeout` bounds any
    # unexpected snapd interaction so the 10-minute hook budget is never consumed.
    if command -v snapctl >/dev/null 2>&1; then
        timeout 120 snapctl stop charmed-postgresql.patroni 2>&1 \
            || echo "migrate-data: WARN 'snapctl stop patroni' failed/timed out; continuing"
    fi
    for _ in $(seq 1 60); do
        pgrep -x postgres >/dev/null 2>&1 || break
        sleep 1
    done

    # Repoint pg_tblspc symlinks from versioned paths back to storage
    # roots so WAL replay works after rollback.  WAL contains Storage
    # CREATE records like "pg_tblspc/24638/PG_16_…/5/…" that use
    # mkdir -p.  If pg_tblspc/24638 is missing or is not a symlink,
    # mkdir -p creates it as a real directory, which then triggers a
    # PANIC in CheckTablespaceDirectory ("unexpected directory entry …
    # All directory entries in pg_tblspc/ should be symbolic links").
    # Replacing the versioned symlink with one pointing to the storage
    # root ensures mkdir -p follows the symlink into the root temp dir.
    for pg_tblspc in "$DATA_VERSIONED/pg_tblspc" "$DATA_ROOT/pg_tblspc"; do
        [ -d "$pg_tblspc" ] || continue
        for entry in "$pg_tblspc"/*; do
            if [ -L "$entry" ]; then
                target=$(readlink "$entry")
                case "$target" in
                    */16/main)
                        root_target="${target%/16/main}"
                        rm "$entry"
                        ln -s "$root_target" "$entry"
                        ;;
                esac
            elif [ -d "$entry" ]; then
                # Directory left by a previous failed WAL replay.
                rm -rf "$entry"
                ln -s "$TEMP_ROOT" "$entry"
            fi
        done
    done

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
    # Temp tablespace catalog is migrated by the charm on the PRIMARY only.
    # But a rolling rollback rolls back replicas BEFORE the primary, so a
    # replica must still replay the forward "CREATE TABLESPACE temp LOCATION
    # '$TEMP_VERSIONED'" WAL record during recovery.  Its redo
    # (create_tablespace_directories) chmod()s that absolute path and FATALs
    # (58P01 "directory ... does not exist") if it is missing -- wedging the
    # replica and stalling the rollback.  So clear any stale contents but KEEP
    # an empty versioned LOCATION dir for replay; the cluster converges to the
    # root layout once the primary migrates the catalog.  Do NOT rmdir the
    # parent "16" dir for the same reason.
    rm -rf "$TEMP_VERSIONED"
    mkdir -p "$TEMP_VERSIONED"
    chmod 700 "$TEMP_VERSIONED"

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
