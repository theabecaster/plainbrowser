# Sourced by the scripts that make simulators (test.sh, matrix.sh, perf-gate.sh).
#
# A brand-new simulator spends its first boot setting itself up (data migration, wallpapers,
# widgets, the system apps' extensions), minutes of CPU on a loaded test Mac, and every script
# used to pay it for every simulator it made. sim_new instead clones a template: a simulator of
# the same device type and runtime, made once per Mac, booted once until that setup was done and
# shut down. A clone is a full copy of the template's data (APFS clones the files), so each job
# still gets its own, unshared device; only the post-setup starting point is shared, and nothing
# ever boots or changes the template after it is made.
#
# Templates are named plain-template-v1-<device type>-<runtime>, stay on the Mac on purpose, and
# are made or rebuilt under /tmp/plain-sim-template.lock, so two jobs never make the same one.
# A template whose runtime is gone (an Xcode update) is deleted and made again. With under 25 GB
# free on the disk no new template is made (about 2 GB each). PLAIN_SIM_TEMPLATES=0
# skips templates and creates every simulator from scratch, as before.

zmodload zsh/datetime 2>/dev/null

# The udid of the simulator with this exact name, or nothing.
sim_udid() {
  xcrun simctl list devices -j | jq -r --arg n "$1" '[.devices[][] | select(.name == $n)][0].udid // empty'
}

# Runs a command with a time limit (seconds). macOS has no `timeout`; the alarm survives exec.
with_timeout() {
  local secs=$1; shift
  perl -e 'alarm shift; exec @ARGV or die "exec: $!"' $secs "$@"
}

# The template for <device type id> <runtime id>, made when missing or broken. Prints its udid,
# or nothing when it can't be made (the caller then creates the simulator from scratch).
sim_template() {
  local type=$1 runtime=$2 name
  name=plain-template-v1-${type##*.}-${runtime##*.}
  /usr/bin/lockf -k -t 900 /tmp/plain-sim-template.lock zsh -c '
    set -u
    name=$1 type=$2 runtime=$3
    json=$(xcrun simctl list devices -j)
    udid=$(jq -r --arg n $name "[.devices[][] | select(.name == \$n)][0].udid // empty" <<<$json)
    ok=$(jq -r --arg n $name "[.devices[][] | select(.name == \$n)][0] | (.isAvailable == true and .state == \"Shutdown\") // false" <<<$json)
    marker=~/Library/Developer/CoreSimulator/Devices/$udid/plain-template-ready
    if [[ -n $udid && $ok == true && -f $marker ]]; then print -r -- $udid; exit 0; fi
    # A template takes about 2 GB. Below 25 GB free, make none (the caller creates the simulator
    # from scratch): a full disk would break every job on the Mac.
    free_kb=$(df -k ~/Library/Developer/CoreSimulator | awk "NR == 2 { print \$4 }")
    (( ${free_kb:-0} > 25 * 1024 * 1024 )) || exit 1
    # Missing, unavailable, half made (no marker) or left booted: make it again.
    [[ -n $udid ]] && { xcrun simctl shutdown $udid 2>/dev/null; xcrun simctl delete $udid 2>/dev/null; }
    udid=$(xcrun simctl create $name $type $runtime) || exit 1
    if ! xcrun simctl boot $udid || ! perl -e "alarm 900; exec @ARGV" xcrun simctl bootstatus $udid -b >/dev/null; then
      xcrun simctl shutdown $udid 2>/dev/null; xcrun simctl delete $udid 2>/dev/null; exit 1
    fi
    # The first boot keeps setting up for a while after bootstatus returns.
    sleep 60
    xcrun simctl shutdown $udid || { xcrun simctl delete $udid 2>/dev/null; exit 1; }
    touch ~/Library/Developer/CoreSimulator/Devices/$udid/plain-template-ready
    print -r -- $udid
  ' sim-template $name $type $runtime 2>/dev/null
}

# Makes simulator <name> (<device type id> <runtime id>), a clone of its template when it can be,
# and prints its udid. Never boots it. The name must start with plain-.
sim_new() {
  local name=$1 type=$2 runtime=$3 template udid
  [[ $name == plain-* && $name != plain-template-* ]] || { print -u2 "sim_new: $name is not a plain-* name"; return 1; }
  if [[ ${PLAIN_SIM_TEMPLATES:-1} != 0 ]] && template=$(sim_template $type $runtime) && [[ -n $template ]]; then
    # Clone under the template lock: the template is never read while it is being remade.
    if udid=$(/usr/bin/lockf -k -t 900 /tmp/plain-sim-template.lock xcrun simctl clone $template $name 2>/dev/null) && [[ -n $udid ]]; then
      print -r -- $udid
      return 0
    fi
  fi
  xcrun simctl create $name $type $runtime
}

# Boots <udid> and waits until it has finished booting (at most 10 minutes).
sim_boot() {
  xcrun simctl boot $1 2>/dev/null || true
  with_timeout 600 xcrun simctl bootstatus $1 >/dev/null
}
