#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbouncer as the non-sudo user: _daemon_.
exec $SNAP/usr/bin/setpriv --clear-groups --reuid _daemon_ \
  --regid _daemon_ -- $SNAP/usr/sbin/pgbouncer "$@"
