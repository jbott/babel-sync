#!/bin/sh
set -u
cd "$(dirname "$0")" || exit 1

failed=0

check() {
  module=$1
  config=$2
  wanted=$3
  scratch=$(mktemp -d)
  started=$(date +%s)
  output=$(nix shell nixpkgs#tlaplus -c tlc -deadlock -workers auto -metadir "$scratch" -config "$config" "$module" 2>&1)
  rm -rf "$scratch"
  seconds=$(($(date +%s) - started))
  states=$(printf '%s\n' "$output" | sed -n 's/.* \([0-9]*\) distinct states found.*/\1/p' | tail -1)

  if [ "$wanted" = "holds" ]; then
    found="No error has been found"
  else
    found="$wanted is violated"
  fi

  if printf '%s\n' "$output" | grep -q "$found"; then
    echo "ok    $config: $wanted (${states:-?} states, ${seconds}s)"
  else
    echo "WRONG $config: expected $wanted"
    printf '%s\n' "$output" | grep -E "Error|violated|No error" | head -5
    failed=1
  fi
}

check Sync.tla Sync.cfg holds
check Sync.tla SyncFeedOnly.cfg "Invariant SyncedMeansEqual"
check Engine.tla Engine.cfg holds
check Engine.tla EngineLive.cfg holds
check Engine.tla EngineStaleCheck.cfg "Invariant NothingLost"
check Engine.tla EngineFirstWrite.cfg "Invariant NothingLost"
check Engine.tla EngineNoIntent.cfg "Invariant BaseMatchesFile"
check Engine.tla EngineSendFirst.cfg "Invariant NothingDuplicated"
check Engine.tla EngineSeqWithoutEntry.cfg "Invariant CursorHonest"
check Engine.tla EngineWriteWindow.cfg "Invariant NothingLost"
check Engine.tla EngineRecoveryAsBriefed.cfg "Invariant NothingLost"
check Engine.tla EngineVacateFileFirst.cfg "Invariant NothingLost"
if [ "${1:-}" = "deep" ]; then check Engine.tla EngineDeep.cfg holds; fi

exit $failed
