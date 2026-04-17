# Pre-Migration Cleanup (before Zig 0.15.2 → 0.16.0)

Goal: remove dead infrastructure, fix the fork rename, and get a working
conformance baseline on 0.15.2 so regressions introduced by the 0.16 upgrade
are easy to spot.

## 1. Delete the Dockerfile

`Dockerfile` pins `zig-linux-aarch64-0.14.0-dev.244+0d79aa017` (an old
nightly) and is not referenced by CI, the Makefile, or the README. Remove it.

```bash
rm Dockerfile
```

## 2. Commit or move `migrate_from_152_to_160.md`

It is currently untracked at the repo root. Commit it to the migration branch
(or move it under a `docs/` directory) so the plan does not get lost.

## 3. Fix the fork rename inside `support/autobahn/`

The repo was renamed `websocket.zig` → `webzocket`, but the Autobahn harnesses
were never updated. They will not build today. Rename the dependency and
import in all six files:

| File | Change |
| --- | --- |
| `support/autobahn/server/build.zig.zon` | `.websocket = ...` → `.webzocket = ...` |
| `support/autobahn/server/build.zig` | `b.dependency("websocket", ...)` → `"webzocket"`; `.module("websocket")` → `.module("webzocket")`; `addImport("websocket", ...)` → `addImport("webzocket", ...)` |
| `support/autobahn/server/main.zig` | `@import("websocket")` → `@import("webzocket")` |
| `support/autobahn/client/build.zig.zon` | same as server `.zon` |
| `support/autobahn/client/build.zig` | same as server `build.zig` |
| `support/autobahn/client/main.zig` | same as server `main.zig` |

While you are in there:

- Add `.minimum_zig_version = "0.15.2"` to both Autobahn `build.zig.zon`
  files. 0.16's manifest parser is stricter.
- `support/autobahn/server/config.json` only lists the `:9224` server, but
  `main.zig` starts two servers (9224 non-blocking, 9225 non-blocking +
  buffer pool). Add a second entry so the buffer-pool path is actually
  covered:

  ```json
  "servers": [
    {"agent": "non-blocking",    "url": "ws://host.docker.internal:9224"},
    {"agent": "non-blocking-bp", "url": "ws://host.docker.internal:9225"}
  ]
  ```

## 4. Establish an Autobahn baseline on 0.15.2

Run `make abs` and `make abc` on the current `master` branch *before*
starting 0.16 work. Commit the `support/autobahn/*/reports/` summary (or at
least record pass/fail counts in the PR description). Without this baseline,
any Autobahn failures after the migration could be pre-existing issues
rather than migration regressions.

## 5. Decide the fate of `Compression`

The compression feature is currently disabled:

- `src/server/server.zig:114` — `init` returns `error.InvalidConfiguraion`
  (note the typo) when `config.compression != null`.
- `src/websocket.zig:25-28` — comment: *"don't know how to support these
  with the Zig 0.15 changes"*.
- `support/autobahn/server/main.zig:56-59, 80-83` — compression config
  commented out with `// zig 0.15`.

0.16 is the natural time to either (a) re-enable compression and exercise it
through Autobahn, or (b) delete the `Compression` struct and the dead
`error.InvalidConfiguraion` branch. Pick one before migrating so you are not
carrying dead code across a Zig version.

## 6. (Optional) Reword `readme.md` for the fork

`readme.md:2-6` still talks about `karlseguin/websocket.zig`, its `dev`
branch, and its wiki. Not migration-blocking, but easy to fix alongside
everything else.

---

# Running Autobahn

## What you need installed

You already have Zig and Python. For Autobahn you additionally need:

- **Docker** (the `run.sh` scripts invoke `docker run crossbario/autobahn-testsuite`).
  On Windows 11, install Docker Desktop with the WSL2 backend.
- **bash**. The scripts are `#!/usr/bin/env bash`. Windows users have two
  options:
  - Run them from **Git Bash** (ships with Git for Windows).
  - Run them from a **WSL2** shell. This is the more reliable option
    because Docker Desktop's WSL2 integration lets containers talk to
    services on `host.docker.internal` cleanly.

Python is **not** actually required — the Autobahn test suite itself
(`wstest`) runs inside the container on PyPy, not on your host Python. Your
local Python install is not used.

Why Docker instead of `pip install autobahntestsuite`: `autobahntestsuite`
is a Python 2.7 package that has not been updated in years. The upstream
project distributes it as a container image precisely because installing it
locally is painful. Stick with Docker.

### First-time Windows checklist

1. Install Docker Desktop, enable WSL2 integration.
2. `docker pull crossbario/autobahn-testsuite` (optional; `run.sh` will
   pull it on first run).
3. From Git Bash or WSL2: `make abs` (server tests) or `make abc` (client
   tests). Reports land in `support/autobahn/{server,client}/reports/`.

## Automation: is the current setup good enough?

The current scripts do one thing right: they use `docker run --rm
crossbario/autobahn-testsuite` with no tag, which resolves to `:latest` and
pulls a fresh image if a newer one is available. You are effectively
auto-tracking upstream.

Gaps worth closing:

### Reproducibility — pin a digest, refresh on a schedule
"Latest" means two developers can run the same `make abs` on the same day
and get different results if the image was republished in between. Pin by
digest so every run of a given commit is identical:

```bash
# in run.sh
crossbario/autobahn-testsuite@sha256:<digest>
```

Get the current digest with:

```bash
docker pull crossbario/autobahn-testsuite
docker inspect --format='{{index .RepoDigests 0}}' crossbario/autobahn-testsuite
```

Then pair that with a scheduled GitHub Actions job (weekly) that pulls
`:latest` and opens a PR if the digest changed. This gives you deterministic
runs *and* automatic upstream tracking, with a human review step before the
new image becomes the baseline.

### CI coverage
Autobahn is not currently wired into `.github/workflows/ci.yml`. The
`ubuntu-latest` runners have Docker preinstalled — adding a job takes about
10 lines:

```yaml
autobahn-server:
  needs: version-check
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: mlugg/setup-zig@v2
      with: { version: "0.15.2" }
    - run: make abs
```

Caveats:
- `make abs` takes 3–5 minutes; consider running it only on PRs that touch
  `src/proto.zig`, `src/server/**`, or `src/client/**` (use `paths:` filter).
- The script currently only `grep FAILED` — consider uploading
  `support/autobahn/server/reports/` as an artifact so failures are
  diagnosable from the Actions UI.
- Run on `ubuntu-latest` only. macOS runners have Docker but it is slow;
  Windows runners do not run Linux containers by default.

### Recommended sequence
1. Pin a digest now (before migration) so the 0.15.2 baseline is
   reproducible.
2. Add the CI job as part of the migration PR — it then gates the
   migration itself.
3. Add the weekly image-refresh automation after the migration settles.

For a one-person / small-team fork, the current shell scripts plus a pinned
digest and one CI job is the right level of investment. More elaborate
automation (matrix testing across Autobahn image versions, historical
dashboards, etc.) is not worth it unless you start diverging substantially
from upstream.
