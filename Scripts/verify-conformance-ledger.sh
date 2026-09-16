#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
features="$root/Tests/Upstream/FEATURES.tsv"
ledger="$root/Tests/Upstream/CONFORMANCE.tsv"

awk -F '\t' '
  FNR == NR {
    if ($0 ~ /^#/ || $1 == "") next
    if (seen[$1]++) { print "duplicate ledger entry: " $1 > "/dev/stderr"; failed=1 }
    if ($2 !~ /^(ported|differential|not-applicable|deferred)$/) {
      print "invalid or missing classification for " $1 ": " $2 > "/dev/stderr"; failed=1
    }
    if ($3 == "") { print "classification lacks evidence: " $1 > "/dev/stderr"; failed=1 }
    classified[$1]=1
    next
  }
  $0 !~ /^#/ && NF >= 2 {
    n=split($2, sources, ",")
    for (i=1; i<=n; i++) { mapped[sources[i]]=1; if (!classified[sources[i]]) missing[sources[i]]=1 }
  }
  END {
    for (source in missing) {
      print "unclassified upstream manifest entry: " source > "/dev/stderr"; failed=1
    }
    for (source in classified) if (!mapped[source]) {
      print "ledger source is not mapped by FEATURES.tsv: " source > "/dev/stderr"; failed=1
    }
    exit failed
  }
' "$ledger" "$features"

if grep -q $'\tdeferred\t' "$ledger"; then
  echo "release conformance ledger still contains deferred work" >&2
  exit 1
fi

echo "all mapped upstream conformance sources are classified with no deferrals"
