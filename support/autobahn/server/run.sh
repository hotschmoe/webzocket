#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

root=$(dirname $(realpath $BASH_SOURCE))

# Fail fast on compile errors — otherwise `zig build run &` silently backgrounds
# the failure and Autobahn runs against nothing, producing an empty reports dir
# that our grep check incorrectly treats as "no failures".
echo "building server..."
(cd "$root" && zig build)

echo "starting server..."
(cd "$root" && zig build run) &
server_pid=$!

sleep 3 # give chance for socket to listen
trap "kill $server_pid 2>/dev/null || true; killall autobahn_test_server 2>/dev/null || true" EXIT

# --add-host lets the container resolve host.docker.internal on Linux Docker
# (where --net=host doesn't auto-add it). Redundant but harmless on Docker Desktop.
docker run --rm \
	--net="host" \
	--add-host=host.docker.internal:host-gateway \
	-v "${root}:/ab" \
	--name fuzzingclient \
	crossbario/autobahn-testsuite \
	/opt/pypy/bin/wstest --mode fuzzingclient --spec /ab/config.json

# Sanity check: if the server never accepted connections, reports/index.json
# will be empty/missing. Treat that as a failure, not a pass.
if [ ! -s "$root/reports/index.json" ]; then
	echo "ERROR: reports/index.json missing or empty — server likely never connected"
	exit 1
fi

if grep -q FAILED "$root"/reports/index.json*; then
	exit 1
fi
exit 0
