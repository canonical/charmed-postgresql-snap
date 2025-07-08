#!/bin/bash

# For security measures, daemons should not be run as sudo. Execute pgbackrest_exporter as the non-sudo user: _daemon_.
$SNAP/usr/bin/setpriv --clear-groups --reuid _daemon_ \
  --regid _daemon_ -- $SNAP/usr/bin/pgbackrest_exporter --backrest.config="/var/snap/charmed-postgresql/current/etc/pgbackrest/pgbackrest.conf" "$@"

