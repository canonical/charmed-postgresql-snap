#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbackrest as the non-sudo user: _daemon_.
$SNAP/usr/bin/setpriv --clear-groups --reuid _daemon_ \
  --regid _daemon_ -- $SNAP/usr/bin/pgbackrest server --config=$SNAP_DATA/etc/pgbackrest/pgbackrest.conf "$@"

