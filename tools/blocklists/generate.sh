#!/bin/sh
# Regenerates the content-blocking lists in Packages/PlainKit/Sources/ContentBlocking/Resources.
# Fetches the lists in tools/blocklists/sources.json, so it needs the network (or pass --offline
# to reuse build/blocklists). Extra arguments go to the tool; see the top of
# tools/blocklists/Sources/plain-blocklists/main.swift.
set -eu
cd "$(dirname "$0")/../.."
# The converter iterates hashed collections. A fixed seed makes every run byte-identical, so
# unchanged lists keep their hashes.
export SWIFT_DETERMINISTIC_HASHING=1
exec swift run -c release --package-path tools/blocklists plain-blocklists "$@"
