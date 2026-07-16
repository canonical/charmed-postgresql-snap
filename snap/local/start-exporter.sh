#!/bin/bash

set -eo pipefail # Exit on error

EXPORTER_OPTS=""
EXPORTER_PATH="/usr/bin/prometheus-postgres-exporter"
SOCKET_PATH="/tmp"

if [ -z "${SNAP}" ]; then
    # When not running as a snap, expect `DATA_SOURCE_URI` to be set.
    if [ -z "${DATA_SOURCE_URI}" ]; then
        echo "Error: DATA_SOURCE_URI must be set" 2>&1
        exit 1
    fi
    exec "${EXPORTER_PATH}" $(echo "${EXPORTER_OPTS}")
else
    # When running as a snap, expect `exporter.user` and `exporter.password`
    DATA_SOURCE_USER="$(snapctl get exporter.user)"
    DATA_SOURCE_PASS="$(snapctl get exporter.password)"
    EXPORTER_PATH="${SNAP}${EXPORTER_PATH}"

    if [[ -z "${DATA_SOURCE_USER}" || -z "${DATA_SOURCE_PASS}" ]]; then
        echo "Error: exporter.user and exporter.password must be set" 2>&1
        exit 1
    fi

    # URL escaped socket path is not allowed by Go.
    DATA_SOURCE_URI=":5432/postgres?host=${SOCKET_PATH}"
    # For security measures, daemons should not be run as sudo.
    # Execute as the non-sudo user: _daemon_.
    exec "${SNAP}"/usr/bin/setpriv \
        --clear-groups \
        --reuid _daemon_ \
        --regid _daemon_ -- \
        env DATA_SOURCE_URI="${DATA_SOURCE_URI}" \
        DATA_SOURCE_USER="${DATA_SOURCE_USER}" \
        DATA_SOURCE_PASS="$DATA_SOURCE_PASS" \
        "${EXPORTER_PATH}" $(echo "${EXPORTER_OPTS}")
fi
