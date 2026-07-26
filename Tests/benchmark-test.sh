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
while [ "$#" -gt 0 ]; do
  if [ "$1" = --state-dir ] && [ "$#" -ge 2 ]; then
    state_dir=$2
    shift 2
  else
    shift
  fi
done
case "$command" in
  start)
    if [ "${TEST_START_MODE:-failure}" = failure ]; then
      echo 'intentional start failure' >&2
      exit 23
    fi
    mkdir -p "$state_dir"
    printf '%s\n' "$$" > "$state_dir/start.pid"
    : > "$state_dir/ready"
    trap 'exit 0' TERM
    while :; do sleep 1; done
    ;;
  ssh)
    [ -f "$state_dir/ready" ]
    exit $?
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
  DARWIN_VZ_NIX_BENCHMARK_TMPDIR="$TMP" TEST_START_MODE=success \
  "$ROOT/scripts/benchmark.sh" collect --execute-vm --iterations 1 --timeout 3 \
  --cli "$TMP/bin/darwin-vz-nix" --kernel "$TMP/kernel" --initrd "$TMP/initrd" \
  --system "$TMP/system" --output "$TMP/success.json" >/dev/null 2>"$TMP/success-stderr"
perl -MJSON::PP -e '
  local $/; my $result = decode_json(<STDIN>);
  die "cold boot failed\n" unless $result->{summary}{cold_boot}{failures} == 0;
  die "warm boot failed\n" unless $result->{summary}{warm_boot}{failures} == 0;
' < "$TMP/success.json"
