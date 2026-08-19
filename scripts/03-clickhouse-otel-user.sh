#!/usr/bin/env bash
# Create the `otel` user (password otelpass) on the ClickHouse in the Lima VM,
# so the collector's exporter can authenticate. Idempotent; run once.
# Requires the Lima VM `clickhouse` to be running.
set -euo pipefail
VM="${VM:-clickhouse}"

echo "Writing /etc/clickhouse-server/users.d/otel.xml in VM '$VM'..."
limactl shell "$VM" -- sudo tee /etc/clickhouse-server/users.d/otel.xml >/dev/null <<'XML'
<clickhouse>
    <users>
        <otel>
            <password>otelpass</password>
            <profile>default</profile>
            <quota>default</quota>
            <networks>
                <ip>::/0</ip>
            </networks>
            <!-- allow CREATE TABLE etc. (collector uses create_schema: true) -->
            <access_management>1</access_management>
        </otel>
    </users>
</clickhouse>
XML

echo "Restarting clickhouse-server..."
limactl shell "$VM" -- sudo systemctl restart clickhouse-server
sleep 3

echo "Verifying otel user from the Mac (Lima forwards localhost:8123)..."
if curl -sS 'http://localhost:8123/?user=otel&password=otelpass' --data-binary 'SELECT 1' | grep -qx 1; then
  echo "OK: otel:otelpass can reach ClickHouse."
else
  echo "WARN: could not authenticate as otel. Check the VM is up and Lima forwards 8123." >&2
  exit 1
fi
echo "Done. Next: ./04-deploy.sh"
