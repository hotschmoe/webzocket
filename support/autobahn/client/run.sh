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

# Give the autobahn fuzzing server time to bind :9001
sleep 3

(cd "$root" && zig build -Doptimize=ReleaseFast run)

if [ ! -s "$root/reports/index.json" ]; then
	echo "ERROR: reports/index.json missing or empty — client never completed a case"
	exit 1
fi

if grep -q FAILED "$root"/reports/index.json*; then
	exit 1
fi
exit 0
