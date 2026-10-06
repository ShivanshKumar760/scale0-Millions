#!/bin/bash
set -e

# Application role (least privilege: owns only the "todo" database) and replication role
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
CREATE ROLE todo LOGIN PASSWORD '$APP_DB_PASSWORD';
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';
ALTER DATABASE "$POSTGRES_DB" OWNER TO todo;
SQL

# "replication" is a special keyword in pg_hba.conf (not a real database): allow replicas anywhere in the VPC
echo "host replication replicator $VPC_CIDR scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Create the two tables (users, todos) as the app role
psql -v ON_ERROR_STOP=1 -U todo -d "$POSTGRES_DB" -f /schema.sql