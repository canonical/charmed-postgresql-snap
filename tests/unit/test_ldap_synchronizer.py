# Copyright 2026 Canonical Ltd.
# See LICENSE file for licensing details.

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import MagicMock, call

import pytest

SCRIPT_PATH = Path(__file__).parents[2] / "snap" / "local" / "scripts" / "ldap-synchronizer.py"

GROUP_IDENTITY = "ldap_users"
GROUP_MAPPINGS = [["ldap-admins", "admins"], ["ldap-readers", "readers"]]

ENV = {
    "LDAP_HOST": "ldap.example.com",
    "LDAP_PORT": "3893",
    "LDAP_BASE_DN": "dc=example,dc=com",
    "LDAP_BIND_USERNAME": "cn=admin,dc=example,dc=com",
    "LDAP_BIND_PASSWORD": "ldap-secret",
    "LDAP_GROUP_IDENTITY": json.dumps(GROUP_IDENTITY),
    "LDAP_GROUP_MAPPINGS": json.dumps(GROUP_MAPPINGS),
    "POSTGRES_HOST": "10.0.0.1",
    "POSTGRES_PORT": "5432",
    "POSTGRES_DATABASE": "postgres",
    "POSTGRES_USERNAME": "operator",
    "POSTGRES_PASSWORD": "psql-secret",
}


class StopLoop(Exception):
    """Raised to break out of the synchronizer infinite loop."""


@pytest.fixture
def synchronizer(monkeypatch):
    """Load the synchronizer script with the postgresql_ldap_sync library stubbed out."""
    clients = ModuleType("postgresql_ldap_sync.clients")
    clients.BaseLDAPClient = object
    clients.BasePostgreClient = object
    clients.DefaultPostgresClient = MagicMock(name="DefaultPostgresClient")
    clients.GLAuthClient = MagicMock(name="GLAuthClient")

    matcher = ModuleType("postgresql_ldap_sync.matcher")
    matcher.DefaultMatcher = MagicMock(name="DefaultMatcher")

    package = ModuleType("postgresql_ldap_sync")
    package.clients = clients
    package.matcher = matcher

    monkeypatch.setitem(sys.modules, "postgresql_ldap_sync", package)
    monkeypatch.setitem(sys.modules, "postgresql_ldap_sync.clients", clients)
    monkeypatch.setitem(sys.modules, "postgresql_ldap_sync.matcher", matcher)

    spec = importlib.util.spec_from_file_location("ldap_synchronizer", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _match(name, keep=False, create=False, delete=False):
    return SimpleNamespace(
        name=name,
        should_keep=keep,
        should_create=create,
        should_delete=delete,
    )


def test_sync_users(synchronizer):
    ldap_client = MagicMock()
    psql_client = MagicMock()
    synchronizer.DefaultMatcher.return_value.match_users.return_value = [
        _match("alice", create=True),
        _match("bob", delete=True),
        _match("carol", keep=True),
    ]

    synchronizer._sync_users(ldap_client, psql_client, GROUP_MAPPINGS, GROUP_IDENTITY)

    ldap_client.search_users.assert_called_once_with(from_groups=["ldap-admins", "ldap-readers"])
    assert psql_client.method_calls == [
        call.search_users(from_group=GROUP_IDENTITY),
        call.create_user("alice"),
        call.grant_group_memberships([GROUP_IDENTITY], ["alice"]),
        call.revoke_group_memberships([GROUP_IDENTITY], ["bob"]),
        call.delete_user("bob"),
    ]


def test_sync_members(synchronizer):
    ldap_client = MagicMock()
    ldap_client.search_users.side_effect = [["alice", "bob"], ["carol"]]
    psql_client = MagicMock()
    psql_client.search_groups.return_value = ["admins", GROUP_IDENTITY, "readers"]

    synchronizer._sync_members(ldap_client, psql_client, GROUP_MAPPINGS, GROUP_IDENTITY)

    assert ldap_client.search_users.call_args_list == [
        call(from_groups=["ldap-admins"]),
        call(from_groups=["ldap-readers"]),
    ]
    # The identity group is never revoked, as it is managed by _sync_users
    assert psql_client.method_calls == [
        call.search_groups(),
        call.revoke_group_memberships(["admins", "readers"], ["alice", "bob"]),
        call.grant_group_memberships(["admins"], ["alice", "bob"]),
        call.revoke_group_memberships(["admins", "readers"], ["carol"]),
        call.grant_group_memberships(["readers"], ["carol"]),
    ]


def test_main(synchronizer, monkeypatch):
    for name, value in ENV.items():
        monkeypatch.setenv(name, value)
    sync_users = MagicMock()
    sync_members = MagicMock()
    time = MagicMock()
    time.sleep.side_effect = [None, StopLoop]
    monkeypatch.setattr(synchronizer, "_sync_users", sync_users)
    monkeypatch.setattr(synchronizer, "_sync_members", sync_members)
    monkeypatch.setattr(synchronizer, "atexit", MagicMock())
    monkeypatch.setattr(synchronizer, "time", time)

    with pytest.raises(StopLoop):
        synchronizer.main()

    synchronizer.GLAuthClient.assert_called_once_with(
        host="ldap.example.com",
        port="3893",
        base_dn="dc=example,dc=com",
        bind_username="cn=admin,dc=example,dc=com",
        bind_password="ldap-secret",
    )
    synchronizer.DefaultPostgresClient.assert_called_once_with(
        host="10.0.0.1",
        port="5432",
        database="postgres",
        username="operator",
        password="psql-secret",
    )
    expected_args = call(
        synchronizer.GLAuthClient.return_value,
        synchronizer.DefaultPostgresClient.return_value,
        GROUP_MAPPINGS,
        GROUP_IDENTITY,
    )
    assert sync_users.call_args_list == [expected_args, expected_args]
    assert sync_members.call_args_list == [expected_args, expected_args]
    assert time.sleep.call_args_list == [call(30), call(30)]