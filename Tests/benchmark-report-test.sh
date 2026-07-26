#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/benchmark-report-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
printf '%s\n' '{"revision":"base","cli_sha256":"sha256-cli-base","guest_artifact_sha256":"sha256-guest","nix_version":"nix 2.31","macos_version":"15.5","hardware_model":"Mac15,6","host_arch":"arm64","iterations":30,"cores":4,"memory_mb":2048,"disk_size":"20G","timeout_seconds":240,"workload_label":"representative_nix_build"}' > "$TMP/meta.json"
i=1
while [ "$i" -le 30 ]; do
  for metric in cold_boot warm_boot ssh_ready shutdown; do
    printf '%s\t%s\t1.0\t1\tsuccess\n' "$i" "$metric" >> "$TMP/samples.tsv"
  done
  if [ "$i" -le 10 ]; then printf '%s\tbuild_workload\t1.0\t1\tsuccess\n' "$i" >> "$TMP/samples.tsv"; fi
  i=$((i + 1))
done
perl "$ROOT/scripts/benchmark-report.pl" collect "$TMP/samples.tsv" "$TMP/meta.json" "$TMP/result.json"
perl -MJSON::PP -e '
  local $/; my $r = decode_json(<STDIN>);
  die unless $r->{schema_version} == 2;
  for my $m (keys %{$r->{summary}}) {
    my $expected = $m eq "build_workload" ? 10 : 30;
    die unless $r->{summary}{$m}{attempts} == $expected;
    die unless $r->{summary}{$m}{failures} == 0;
    die unless $r->{summary}{$m}{failure_rate} == 0;
    die unless $r->{summary}{$m}{median_seconds} == 1;
  }
' < "$TMP/result.json"
perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/result.json" > "$TMP/compare.json"
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); die unless $r->{verdict} eq "informational"' < "$TMP/compare.json"
perl -MJSON::PP -e '
  local $/; my $r=decode_json(<STDIN>);
  $r->{metadata}{revision}="candidate"; $r->{metadata}{cli_sha256}="sha256-cli-candidate";
  $r->{summary}{cold_boot}{failures}=1; $r->{summary}{cold_boot}{failure_rate}=1/30;
  print JSON::PP->new->canonical->encode($r)
' < "$TMP/result.json" > "$TMP/candidate.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/candidate.json" 5 > "$TMP/regression.json"; then
  echo 'zero-baseline failure-rate regression was accepted' >&2; exit 1
fi
perl -MJSON::PP -e '
  local $/; my $r=decode_json(<STDIN>); my $m=$r->{metrics}{cold_boot}{failure_rate};
  die unless $r->{verdict} eq "regression" && $m->{comparison_status} eq "regressed";
  die unless !defined($m->{change_percent}) && $m->{absolute_change} > 0;
' < "$TMP/regression.json"
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); $r->{schema_version}=1; print encode_json($r)' < "$TMP/result.json" > "$TMP/invalid.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/invalid.json" 5 >/dev/null 2>&1; then
  echo 'invalid schema was accepted' >&2; exit 1
fi
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); $r->{metadata}{hardware_model}="different"; print encode_json($r)' < "$TMP/result.json" > "$TMP/invalid.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/invalid.json" 5 >/dev/null 2>&1; then
  echo 'metadata mismatch was accepted' >&2; exit 1
fi
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); delete $r->{summary}{warm_boot}{p95_seconds}; print encode_json($r)' < "$TMP/result.json" > "$TMP/invalid.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/invalid.json" 5 >/dev/null 2>&1; then
  echo 'missing statistic was accepted' >&2; exit 1
fi
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); $r->{summary}{build_workload}{attempts}=9; print encode_json($r)' < "$TMP/result.json" > "$TMP/invalid.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/invalid.json" 5 >/dev/null 2>&1; then
  echo 'insufficient sample count was accepted' >&2; exit 1
fi
perl -MJSON::PP -e 'local $/; my $r=decode_json(<STDIN>); $r->{summary}{shutdown}{median_seconds}="invalid"; print encode_json($r)' < "$TMP/result.json" > "$TMP/invalid.json"
if perl "$ROOT/scripts/benchmark-report.pl" compare "$TMP/result.json" "$TMP/invalid.json" 5 >/dev/null 2>&1; then
  echo 'non-numeric statistic was accepted' >&2; exit 1
fi
if DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=0 "$ROOT/scripts/benchmark.sh" collect --execute-vm >/dev/null 2>&1; then
  echo 'safety interlock failed' >&2; exit 1
fi
