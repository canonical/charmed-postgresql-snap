#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute patroni as the non-sudo user: snap_daemon.
$SNAP/usr/bin/setpriv --clear-groups --reuid snap_daemon \
  --regid snap_daemon -- $SNAP/usr/bin/patroni $SNAP_DATA/etc/patroni/patroni.yaml "$@"

