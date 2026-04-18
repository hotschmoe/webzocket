F=
zig ?= zig

# The Io-native server has no blocking/nonblocking split (one path per
# platform). `tn` / `tb` / `t` all resolve to the same single run now —
# kept as aliases so muscle memory (and CI) doesn't break.
.PHONY: t tn tb
t tn tb:
	TEST_FILTER='${F}' '${zig}' build test -freference-trace --summary all

.PHONY: abs
abs:
	bash support/autobahn/server/run.sh

.PHONY: abc
abc:
	bash support/autobahn/client/run.sh
