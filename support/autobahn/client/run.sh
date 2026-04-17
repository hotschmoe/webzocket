#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

docker stop fuzzingserver 2>/dev/null || true

root=$(dirname $(realpath $BASH_SOURCE))
trap "docker stop fuzzingserver 2>/dev/null || true" EXIT

docker run --rm \
	-p 9001:9001 \
	-v "${root}:/ab" \
	--name fuzzingserver \
	crossbario/autobahn-testsuite \
	/opt/pypy/bin/wstest --mode fuzzingserver --spec /ab/config.json &

# Wait up to 30s for the Autobahn fuzzing server to bind :9001.
echo "waiting for fuzzingserver port to bind..."
for i in {1..60}; do
	if (echo > /dev/tcp/127.0.0.1/9001) 2>/dev/null; then
		echo "fuzzingserver ready after ${i} attempts"
		break
	fi
	if [ "$i" = "60" ]; then
		echo "ERROR: fuzzingserver did not bind within 30s"
		exit 1
	fi
	sleep 0.5
done

(cd "$root" && zig build -Doptimize=ReleaseFast run)

reports="$root/reports/index.json"
if [ ! -s "$reports" ]; then
	echo "ERROR: reports/index.json missing or empty — client never completed a case"
	exit 1
fi
if ! grep -q '"behavior"' "$reports"; then
	echo "ERROR: reports/index.json contains no case results"
	cat "$reports"
	exit 1
fi

if grep -q FAILED "$root"/reports/index.json*; then
	echo "ERROR: at least one case reported FAILED behavior"
	exit 1
fi
exit 0
