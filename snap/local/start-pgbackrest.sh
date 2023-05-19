#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbackrest as the non-sudo user: snap_daemon.
$SNAP/usr/bin/setpriv --clear-groups --reuid snap_daemon \
  --regid snap_daemon -- $SNAP/usr/bin/pgbackrest server --config=$SNAP_DATA/etc/pgbackrest/pgbackrest.conf "$@"

