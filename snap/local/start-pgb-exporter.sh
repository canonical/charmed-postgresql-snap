#!/bin/bash

set -eo pipefail # Exit on error

EXPORTER_OPTS=""
EXPORTER_PATH="/usr/bin/prometheus-pgbouncer-exporter"
SOCKET_PATH="/tmp"

if [ -z "${SNAP}" ]; then
    # When not running as a snap, expect `DATA_SOURCE_NAME` to be set.
    if [ -z "${DATA_SOURCE_NAME}" ]; then
        echo "Error: DATA_SOURCE_NAME must be set" 2>&1
        exit 1
    fi
    exec "${EXPORTER_PATH}" $(echo "${EXPORTER_OPTS}")
else
    # When running as a snap, expect `exporter.user` and `exporter.password`
    EXPORTER_USER="$(snapctl get exporter.user)"
    EXPORTER_PASS="$(snapctl get exporter.password)"
    EXPORTER_PATH="${SNAP}${EXPORTER_PATH}"

    if [[ -z "${EXPORTER_USER}" || -z "${EXPORTER_PASS}" ]]; then
        echo "Error: exporter.user and exporter.password must be set" 2>&1
        exit 1
    fi

    DATA_SOURCE_NAME="user=${EXPORTER_USER} password=${EXPORTER_PASS} host=${SOCKET_PATH}"
    DATA_SOURCE_NAME+=" port=5432 database=postgres"
    # For security measures, daemons should not be run as sudo.
    # Execute as the non-sudo user: snap_daemon.
    exec "${SNAP}"/usr/bin/setpriv \
        --clear-groups \
        --reuid snap_daemon \
        --regid snap_daemon -- \
        env DATA_SOURCE_NAME="${DATA_SOURCE_NAME}" \
        "${EXPORTER_PATH}" $(echo "${EXPORTER_OPTS}")
fi
