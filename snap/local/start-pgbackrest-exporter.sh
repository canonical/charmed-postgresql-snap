#!/bin/bash

set -eo pipefail

if [ -z "${SNAP}" ]; then
    exec /usr/bin/pgbackrest_exporter \
        --backrest.config="/etc/pgbackrest.conf" "$@"
else
    exec "${SNAP}/usr/bin/setpriv" \
        --clear-groups \
        --reuid _daemon_ \
        --regid _daemon_ -- \
        "${SNAP}/usr/bin/pgbackrest_exporter" \
        --backrest.config="/var/snap/charmed-postgresql/current/etc/pgbackrest/pgbackrest.conf" "$@"
fi

