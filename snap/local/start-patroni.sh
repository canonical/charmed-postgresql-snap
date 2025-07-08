#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute patroni as the non-sudo user: _daemon_.
export LOCPATH="${SNAP}"/usr/lib/locale
$SNAP/usr/bin/setpriv --clear-groups --reuid _daemon_ \
  --regid _daemon_ -- $SNAP/usr/bin/patroni $SNAP_DATA/etc/patroni/patroni.yaml "$@"

