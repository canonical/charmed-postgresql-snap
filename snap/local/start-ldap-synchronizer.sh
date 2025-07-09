#!/bin/bash

# Exit on error
set -eo pipefail

SHELL_SCRIPTS_PATH="$(realpath $(dirname $0))"
PYTHON_SCRIPT_PATH="${SHELL_SCRIPTS_PATH}/scripts/ldap-synchronizer.py"

if [ -z "${SNAP}" ]; then
  exec /usr/bin/python3 ${PYTHON_SCRIPT_PATH}
  exit 0
fi

# For security measures, daemons should not be run as sudo.
# Execute as the non-sudo user: _daemon_.
exec "${SNAP}"/usr/bin/setpriv \
  --clear-groups \
  --reuid _daemon_ \
  --regid _daemon_ -- \
  env LDAP_HOST="$(snapctl get ldap-sync.ldap_host)" \
  env LDAP_PORT="$(snapctl get ldap-sync.ldap_port)" \
  env LDAP_BASE_DN="$(snapctl get ldap-sync.ldap_base_dn)" \
  env LDAP_BIND_USERNAME="$(snapctl get ldap-sync.ldap_bind_username)" \
  env LDAP_BIND_PASSWORD="$(snapctl get ldap-sync.ldap_bind_password)" \
  env LDAP_GROUP_IDENTITY="$(snapctl get ldap-sync.ldap_group_identity)" \
  env LDAP_GROUP_MAPPINGS="$(snapctl get ldap-sync.ldap_group_mappings)" \
  env POSTGRES_HOST="$(snapctl get ldap-sync.postgres_host)" \
  env POSTGRES_PORT="$(snapctl get ldap-sync.postgres_port)" \
  env POSTGRES_DATABASE="$(snapctl get ldap-sync.postgres_database)" \
  env POSTGRES_USERNAME="$(snapctl get ldap-sync.postgres_username)" \
  env POSTGRES_PASSWORD="$(snapctl get ldap-sync.postgres_password)" \
  $SNAP/bin/python3 ${PYTHON_SCRIPT_PATH}
