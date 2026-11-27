# Sourced by scripts that run builds and tests on a test Mac instead of this one (after
# lib/common.zsh, which sets ROOT). docs/development.md, "Test Macs".
#
# The host comes from PLAIN_TEST_HOST (the environment, or the gitignored scripts/local.env); it
# is an ssh host name, never written in the repo. Each checkout gets its own lane on the host,
# ~/plain-lanes/<lane> (PLAIN_LANE, default this checkout's folder name), and every command runs
# under the host's simulator lock (/tmp/plain-sim.lock), so one simulator job runs there at a time.

# The default test host, or nothing.
remote_default_host() {
  if [[ -z ${PLAIN_TEST_HOST:-} && -f $ROOT/scripts/local.env ]]; then
    (source $ROOT/scripts/local.env; print -r -- ${PLAIN_TEST_HOST:-})
  else
    print -r -- ${PLAIN_TEST_HOST:-}
  fi
}

remote_lane() {
  local lane=${PLAIN_LANE:-${ROOT:t}}
  [[ $lane =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "PLAIN_LANE must be letters, digits, . _ -"; return 1; }
  print -r -- $lane
}

# Copies this checkout to <host>:~/plain-lanes/<lane> (no .git, no build output, no local.env),
# with the gitignored signing config from the main checkout, and snapshots it there as a git repo
# (the scripts call git).
remote_sync() {
  local host=$1 lane=$2 main
  rsync -az --delete --exclude build --exclude .build --exclude '*.xcodeproj' --exclude .git \
    --exclude scripts/local.env "$ROOT/" "$host:plain-lanes/$lane/"
  main=$(git -C $ROOT rev-parse --path-format=absolute --git-common-dir)
  main=${main:h}
  [[ -f $main/Config/Signing.local.xcconfig ]] \
    && rsync -az $main/Config/Signing.local.xcconfig "$host:plain-lanes/$lane/Config/"
  ssh $host "cd ~/plain-lanes/$lane && { [ -d .git ] || git init -q; git add -A >/dev/null 2>&1; git -c user.email=lane@local -c user.name=lane commit -qm snapshot >/dev/null 2>&1 || true; }"
}

# Syncs, then runs <command> in the lane under the host's simulator lock, in a login shell (for
# Homebrew's PATH). Returns the command's exit status.
remote_run() {
  local host=$1 lane=$2 cmd=$3
  remote_sync $host $lane
  ssh $host "cd ~/plain-lanes/$lane && /usr/bin/lockf -k /tmp/plain-sim.lock zsh -lc ${(q)cmd}"
}

# Copies <path> from the lane to <dest> here; extra arguments go to rsync.
remote_pull() {
  local host=$1 lane=$2 src=$3 dest=$4
  shift 4
  rsync -az "$@" "$host:plain-lanes/$lane/$src" "$dest"
}

# Removes the lane from the host. Delete your plain-* simulators there first.
remote_clean() {
  ssh $1 "rm -rf ~/plain-lanes/$2"
}
