#!/bin/bash

exec "$SNAP/usr/bin/setpriv" --clear-groups --reuid _daemon_ --regid _daemon_ -- "$@"
