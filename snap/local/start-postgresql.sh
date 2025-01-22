#!/bin/bash

# For security measures, applications should not be run as sudo.
export LOCPATH="${SNAP}"/usr/lib/locale
export PGDATA=$SNAP_DATA/pgsql/data

mkdir /home/snap_daemon
chown -R 584788:root /home/snap_daemon
usermod -d /home/snap_daemon snap_daemon

echo "Starting PostgreSQL database..."
"${SNAP}/usr/bin/setpriv" --clear-groups --reuid snap_daemon --regid snap_daemon -- "${SNAP}/usr/lib/postgresql/14/bin/postgres" -k /tmp -D "${PGDATA}"

