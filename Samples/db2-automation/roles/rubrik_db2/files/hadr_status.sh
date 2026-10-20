#!/bin/bash
# Run as the Db2 instance owner. Prints "<database> <role>" for every local database that has
# HADR configured, where role is PRIMARY, STANDBY or UNKNOWN (db2pd could not tell, e.g. the
# database is not activated). Prints nothing when no database uses HADR.

# Under sudo $HOME can still be the connecting user's, so resolve the home of the current
# user. DB2_PROFILE overrides the location (for testing).
home=$(eval echo "~$(id -un)")
profile="${DB2_PROFILE:-$home/sqllib/db2profile}"
if [ ! -r "$profile" ]; then
  echo "Db2 profile not found: $profile" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$profile"

# Local databases only (directory entry type Indirect), not catalogued remote ones.
db2 list db directory 2>/dev/null \
  | awk '/Database name/ {n=$NF} /Directory entry type/ && $NF=="Indirect" {print n}' \
  | while read -r db; do
      hadr_host=$(db2 get db cfg for "$db" 2>/dev/null \
        | awk -F= '/\(HADR_LOCAL_HOST\)/ {gsub(/[[:space:]]/, "", $2); print $2}')
      [ -n "$hadr_host" ] || continue
      role=$(db2pd -db "$db" -hadr 2>/dev/null | awk '/HADR_ROLE/ {print $NF; exit}')
      echo "$db ${role:-UNKNOWN}"
    done
exit 0
