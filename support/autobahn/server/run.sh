#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

root=$(dirname $(realpath $BASH_SOURCE))

# Fail fast on compile errors — otherwise `zig build run &` silently backgrounds
# the failure and Autobahn runs against nothing, producing an empty reports dir.
echo "building server..."
(cd "$root" && zig build)

echo "starting server..."
(cd "$root" && zig build run) &
server_pid=$!
trap "kill $server_pid 2>/dev/null || true; killall autobahn_test_server 2>/dev/null || true" EXIT

# Wait up to 30s for both ports to accept connections. `zig build run` does
# a cache-check before exec, plus the library initializes thread pools and
# handshake pools — a static `sleep 3` can race on slow CI runners.
echo "waiting for server ports to bind..."
for i in {1..60}; do
	if (echo > /dev/tcp/127.0.0.1/9224) 2>/dev/null && (echo > /dev/tcp/127.0.0.1/9225) 2>/dev/null; then
		echo "server ready after ${i} attempts"
		break
	fi
	if [ "$i" = "60" ]; then
		echo "ERROR: server did not bind within 30s"
		exit 1
	fi
	sleep 0.5
done

# Use 127.0.0.1 (not host.docker.internal) + --net=host so the container can
# reach the host zig server over loopback reliably on Linux Docker. Docker
# Desktop on Mac/Windows treats --net=host differently; local dev on those
# platforms is expected to edit config.json or use WSL.
docker run --rm \
	--net="host" \
	-v "${root}:/ab" \
	--name fuzzingclient \
	crossbario/autobahn-testsuite \
	/opt/pypy/bin/wstest --mode fuzzingclient --spec /ab/config.json

# Sanity: Autobahn writes reports/index.json eagerly (with just agent keys)
# even if no cases ran. To detect that real cases ran, require at least one
# "behavior" entry (present in every successful or failed case result).
reports="$root/reports/index.json"
if [ ! -s "$reports" ]; then
	echo "ERROR: reports/index.json missing or empty"
	exit 1
fi
if ! grep -q '"behavior"' "$reports"; then
	echo "ERROR: reports/index.json contains no case results — server likely never accepted"
	cat "$reports"
	exit 1
fi

if grep -q FAILED "$root"/reports/index.json*; then
	echo "ERROR: at least one case reported FAILED behavior"
	exit 1
fi
exit 0
