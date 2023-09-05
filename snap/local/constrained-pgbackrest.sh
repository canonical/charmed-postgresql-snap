#!/bin/bash

# Constrained pgbackrest within the snap
exec $SNAP/usr/bin/setpriv --clear-groups --reuid snap_daemon \
  --regid snap_daemon -- $SNAP/usr/bin/pgbackrest "$@"
