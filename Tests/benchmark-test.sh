#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/benchmark-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/system"
: > "$TMP/kernel"
: > "$TMP/initrd"
printf '#!/bin/sh\nexit 0\n' > "$TMP/system/init"
chmod +x "$TMP/system/init"

cat > "$TMP/bin/darwin-vz-nix" <<'EOF'
#!/bin/sh
command=$1
shift
state_dir=
ssh_command=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --state-dir ] && [ "$#" -ge 2 ]; then
    state_dir=$2
    shift 2
  elif [ "$1" = -- ]; then
    shift
    ssh_argument_count=$#
    ssh_command=${1:-}
    break
  else
    shift
  fi
done
case "$command" in
  start)
    if [ -n "${TEST_START_LOG:-}" ]; then
      printf '%s\n' "$state_dir" >> "$TEST_START_LOG"
    fi
    if [ "${TEST_START_MODE:-failure}" = failure ]; then
      echo 'intentional start failure' >&2
      exit 23
    fi
    mkdir -p "$state_dir"
    exec perl -MFcntl=:flock -MTime::HiRes=sleep -e '
      open my $lock, ">>", "$ARGV[0]/vm.lock" or die $!;
      flock($lock, LOCK_EX | LOCK_NB) or die "overlapping VM start\n";
      open my $pid, ">", "$ARGV[0]/start.pid" or die $!;
      print {$pid} "$$\n"; close $pid;
      open my $ready, ">", "$ARGV[0]/ready" or die $!; close $ready;
      $SIG{TERM} = sub {
        unlink "$ARGV[0]/ready";
        sleep(0 + ($ENV{TEST_LOCK_RELEASE_DELAY} // 0));
        exit 0;
      };
      sleep 1 while 1;
    ' "$state_dir"
    ;;
  ssh)
    [ -f "$state_dir/ready" ] || exit 1
    if [ -n "${TEST_SSH_COMMAND_LOG:-}" ]; then
      printf '%s\t%s\n' "$ssh_argument_count" "$ssh_command" >> "$TEST_SSH_COMMAND_LOG"
    fi
    if [ "${ssh_command#sh -lc }" != "$ssh_command" ] && \
       [ "${TEST_WORKLOAD_MODE:-success}" = failure ]; then
      printf 'private workload diagnostic\n' >&2
      exit 42
    fi
    exit 0
    ;;
  stop)
    rm -f "$state_dir/ready"
    if [ -f "$state_dir/start.pid" ]; then
      kill -TERM "$(cat "$state_dir/start.pid")" 2>/dev/null || true
    fi
    exit 0
    ;;
esac
exit 64
EOF
cat > "$TMP/bin/nix" <<'EOF'
#!/bin/sh
case "$1 $2" in
  'hash file') printf 'sha256-cli\n' ;;
  'hash path') printf 'sha256-guest\n' ;;
  '--version ') printf 'nix (test) 1.0\n' ;;
  *) exit 64 ;;
esac
EOF
cat > "$TMP/bin/sw_vers" <<'EOF'
#!/bin/sh
printf 'test-macos\n'
EOF
cat > "$TMP/bin/sysctl" <<'EOF'
#!/bin/sh
printf 'test-hardware\n'
EOF
chmod +x "$TMP/bin/"*

start=$(perl -MTime::HiRes=time -e 'print time')
PATH="$TMP/bin:$PATH" DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1 \
  DARWIN_VZ_NIX_BENCHMARK_TMPDIR="$TMP" \
  "$ROOT/scripts/benchmark.sh" collect --execute-vm --iterations 1 --timeout 10 \
  --cli "$TMP/bin/darwin-vz-nix" --kernel "$TMP/kernel" --initrd "$TMP/initrd" \
  --system "$TMP/system" --output "$TMP/failure.json" >"$TMP/stdout" 2>"$TMP/stderr"
elapsed=$(perl -MTime::HiRes=time -e 'print time - $ARGV[0]' "$start")
perl -e 'exit($ARGV[0] < 5 ? 0 : 1)' "$elapsed" || {
  echo "early start failure took too long: ${elapsed}s" >&2
  exit 1
}
perl -0777 -ne 'exit(index($_, "VM start process exited before SSH became ready") >= 0 && index($_, "intentional start failure") >= 0 ? 0 : 1)' \
  "$TMP/stderr" || {
  echo 'start failure diagnostics were not reported' >&2
  exit 1
}
perl -MJSON::PP -e '
  local $/; my $result = decode_json(<STDIN>);
  die unless $result->{summary}{cold_boot}{failures} == 1;
  die unless $result->{summary}{shutdown}{attempts} == 1;
' < "$TMP/failure.json"

PATH="$TMP/bin:$PATH" DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1 \
  DARWIN_VZ_NIX_BENCHMARK_TMPDIR="$TMP" TEST_START_MODE=success TEST_LOCK_RELEASE_DELAY=1 \
  TEST_SSH_COMMAND_LOG="$TMP/ssh-commands" TEST_START_LOG="$TMP/starts" \
  "$ROOT/scripts/benchmark.sh" collect --execute-vm --iterations 2 --timeout 3 \
  --cli "$TMP/bin/darwin-vz-nix" --kernel "$TMP/kernel" --initrd "$TMP/initrd" \
  --system "$TMP/system" --output "$TMP/success.json" >/dev/null 2>"$TMP/success-stderr"
perl -MJSON::PP -e '
  local $/; my $result = decode_json(<STDIN>);
  die "cold boot failed\n" unless $result->{summary}{cold_boot}{failures} == 0;
  die "warm boot failed\n" unless $result->{summary}{warm_boot}{failures} == 0;
  die "workload failed\n" unless $result->{summary}{build_workload}{failures} == 0;
  die "wrong workload label\n" unless $result->{metadata}{workload_label} eq "offline_nix_derivation_rebuild";
' < "$TMP/success.json" || {
  perl -ne 'print' "$TMP/success-stderr" >&2
  exit 1
}
perl -F'\t' -lane '
  next unless $F[1] =~ /^sh -lc /;
  die "workload was not passed as one remote argument\n" unless $F[0] == 1;
  die "workload is not a forced rebuild\n" unless $F[1] =~ /nix build --no-link --rebuild --expr/;
  die "workload is not the fixed offline derivation\n" unless $F[1] =~ /builtins\.derivation/ && $F[1] =~ /aarch64-linux/;
  $count++;
  END { die "expected one workload per iteration (got " . (0 + $count) . ")\n" unless $count == 2 }
' "$TMP/ssh-commands" || {
  echo 'default workload invocation is not isolated and reproducible' >&2
  exit 1
}
test "$(perl -lne '$count++; END { print 0 + $count }' "$TMP/starts")" = 4 || {
  echo 'benchmark did not perform exactly one cold and one warm start per iteration' >&2
  exit 1
}

custom_workload='printf "%s\\n" "apostrophe:'\'' space; dollar:$HOME" && true'
PATH="$TMP/bin:$PATH" DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1 \
  DARWIN_VZ_NIX_BENCHMARK_TMPDIR="$TMP" TEST_START_MODE=success \
  TEST_SSH_COMMAND_LOG="$TMP/custom-ssh-command" \
  "$ROOT/scripts/benchmark.sh" collect --execute-vm --iterations 1 --timeout 3 \
  --cli "$TMP/bin/darwin-vz-nix" --kernel "$TMP/kernel" --initrd "$TMP/initrd" \
  --system "$TMP/system" --workload-command "$custom_workload" \
  --output "$TMP/custom-workload.json" >/dev/null 2>"$TMP/custom-workload-stderr"
CUSTOM_WORKLOAD=$custom_workload perl -F'\t' -lane '
  next unless $F[1] =~ /^sh -lc /;
  die "workload was not passed as one argument\n" unless $F[0] == 1;
  my $expected = $ENV{CUSTOM_WORKLOAD};
  $expected =~ s/'\''/'\''"'\''"'\''/g;
  die "workload quoting changed\n" unless $F[1] eq "sh -lc '\''$expected'\''";
  $matched = 1;
  END { die "workload invocation missing\n" unless $matched }
' "$TMP/custom-ssh-command"
perl -MJSON::PP -e '
  local $/; my $result = decode_json(<STDIN>);
  die "custom workload label changed\n" unless $result->{metadata}{workload_label} eq "custom_guest_command";
' < "$TMP/custom-workload.json"

PATH="$TMP/bin:$PATH" DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1 \
  DARWIN_VZ_NIX_BENCHMARK_TMPDIR="$TMP" TEST_START_MODE=success TEST_WORKLOAD_MODE=failure \
  "$ROOT/scripts/benchmark.sh" collect --execute-vm --iterations 1 --timeout 3 \
  --cli "$TMP/bin/darwin-vz-nix" --kernel "$TMP/kernel" --initrd "$TMP/initrd" \
  --system "$TMP/system" --output "$TMP/workload-failure.json" \
  >"$TMP/workload-stdout" 2>"$TMP/workload-stderr"
test -f "$TMP/workload-failure.json.diagnostics/workload-iteration-1.log"
test "$(stat -f '%Lp' "$TMP/workload-failure.json.diagnostics/workload-iteration-1.log")" = 600
perl -0777 -ne 'exit(index($_, "private workload diagnostic") < 0 ? 0 : 1)' "$TMP/workload-stderr" || {
  echo 'workload diagnostic leaked to stderr' >&2
  exit 1
}
perl -0777 -ne 'exit(index($_, "private workload diagnostic") >= 0 ? 0 : 1)' \
  "$TMP/workload-failure.json.diagnostics/workload-iteration-1.log" || {
  echo 'private workload diagnostic was not retained' >&2
  exit 1
}
