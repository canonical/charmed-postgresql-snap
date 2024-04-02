#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbackrest_exporter as the non-sudo user: snap_daemon.
$SNAP/usr/bin/setpriv --clear-groups --reuid snap_daemon \
  --regid snap_daemon -- $SNAP/usr/bin/pgbackrest_exporter --backrest.config="/var/snap/charmed-postgresql/current/etc/pgbackrest/pgbackrest.conf" "$@"

