#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbouncer_exporter as the non-sudo user: snap_daemon.
exec $SNAP/usr/bin/setpriv --clear-groups --reuid snap_daemon \
  --regid snap_daemon -- $SNAP/usr/bin/pgbouncer_exporter "$@"
