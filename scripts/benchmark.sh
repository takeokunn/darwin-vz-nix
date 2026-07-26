#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  benchmark.sh collect --execute-vm --kernel PATH --initrd PATH --system PATH [options]
  benchmark.sh compare BASELINE.json CANDIDATE.json [--max-regression-percent N]

collect options: --output FILE --iterations N --cli PATH --cores N --memory MB
                 --disk-size SIZE --timeout SECONDS --workload-command COMMAND

VM collection additionally requires DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1.
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = compare ]; then
  shift
  [ "$#" -ge 2 ] || { usage >&2; exit 64; }
  BASELINE=$1 CANDIDATE=$2 THRESHOLD=
  shift 2
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --max-regression-percent ] || { usage >&2; exit 64; }
    THRESHOLD=$2
  fi
  exec perl "$SCRIPT_DIR/benchmark-report.pl" compare "$BASELINE" "$CANDIDATE" ${THRESHOLD:+"$THRESHOLD"}
fi
[ "${1:-}" = collect ] || { usage >&2; exit 64; }
shift

OUTPUT=benchmark-results.json ITERATIONS=30 CLI=darwin-vz-nix CORES=4 MEMORY=2048 DISK_SIZE=20G TIMEOUT=240
WORKLOAD_ITERATIONS=10
KERNEL=''
INITRD=''
SYSTEM=''
EXECUTE=0
WORKLOAD='nix build --no-link nixpkgs#hello'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --execute-vm) EXECUTE=1; shift ;;
    --output|--iterations|--cli|--cores|--memory|--disk-size|--timeout|--workload-command|--kernel|--initrd|--system)
      [ "$#" -ge 2 ] || { echo "$1 requires a value" >&2; exit 64; }
      key=$1 value=$2; shift 2
      case "$key" in
        --output) OUTPUT=$value ;; --iterations) ITERATIONS=$value ;; --cli) CLI=$value ;;
        --cores) CORES=$value ;; --memory) MEMORY=$value ;; --disk-size) DISK_SIZE=$value ;;
        --timeout) TIMEOUT=$value ;; --workload-command) WORKLOAD=$value ;; --kernel) KERNEL=$value ;;
        --initrd) INITRD=$value ;; --system) SYSTEM=$value ;;
      esac ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
[ "$EXECUTE" -eq 1 ] && [ "${DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM:-}" = 1 ] || {
  echo "refusing VM operations: pass --execute-vm and set DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1" >&2; exit 64;
}
positive_integer() { case "$1" in ''|*[!0-9]*|0) return 1;; *) return 0;; esac; }
if ! positive_integer "$ITERATIONS" || ! positive_integer "$CORES" \
  || ! positive_integer "$MEMORY" || ! positive_integer "$TIMEOUT"; then
  echo "numeric options must be positive integers" >&2; exit 64;
fi
[ -f "$KERNEL" ] && [ -f "$INITRD" ] && [ -x "$SYSTEM/init" ] || { echo "kernel, initrd, or system/init is invalid" >&2; exit 64; }
command -v "$CLI" >/dev/null 2>&1 || [ -x "$CLI" ] || { echo "CLI not executable: $CLI" >&2; exit 64; }
case "$CLI" in */*) ;; *) CLI=$(command -v "$CLI") ;; esac

DEFAULT_TMP_BASE=
DEFAULT_TMP_ROOT=
if [ -n "${DARWIN_VZ_NIX_BENCHMARK_TMPDIR:-}" ]; then
  TMP_BASE=$DARWIN_VZ_NIX_BENCHMARK_TMPDIR
elif [ -n "${TMPDIR:-}" ]; then
  TMP_BASE=$TMPDIR
else
  [ -n "${HOME:-}" ] || {
    echo "HOME must be set when DARWIN_VZ_NIX_BENCHMARK_TMPDIR and TMPDIR are unset" >&2
    exit 64
  }
  DEFAULT_TMP_ROOT=$HOME/Library/Caches/darwin-vz-nix
  DEFAULT_TMP_BASE=$DEFAULT_TMP_ROOT/benchmark
  TMP_BASE=$DEFAULT_TMP_BASE
fi
umask 077
mkdir -p "$TMP_BASE"
if [ -n "$DEFAULT_TMP_BASE" ]; then
  chmod 700 "$DEFAULT_TMP_ROOT" "$TMP_BASE"
fi
TMP_ROOT=$(mktemp -d "$TMP_BASE/darwin-vz-nix-benchmark.XXXXXX")
STATE_DIR=$TMP_ROOT/state
SAMPLES=$TMP_ROOT/samples.tsv
METADATA=$TMP_ROOT/metadata.json
START_LOG=$TMP_ROOT/start.log
START_STATUS=$TMP_ROOT/start.status
START_PID=
STOP_PID=
cleanup() {
  if [ -n "$STOP_PID" ] && kill -0 "$STOP_PID" 2>/dev/null; then terminate_and_wait "$STOP_PID" 5; fi
  if [ -n "$START_PID" ] && kill -0 "$START_PID" 2>/dev/null; then terminate_and_wait "$START_PID" 5; fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM
: > "$SAMPLES"

now() { perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
elapsed() { perl -e 'printf "%.6f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"; }
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$SAMPLES"; }
wait_pid_until() {
  wait_pid=$1 wait_limit=$2
  wait_deadline=$(perl -MTime::HiRes=time -e 'printf "%.6f\n", time + $ARGV[0]' "$wait_limit")
  while kill -0 "$wait_pid" 2>/dev/null; do
    perl -MTime::HiRes=time -e 'exit(time < $ARGV[0] ? 0 : 1)' "$wait_deadline" || return 1
    sleep 1
  done
  wait "$wait_pid" 2>/dev/null
}
terminate_and_wait() {
  terminate_pid=$1 terminate_grace=$2
  kill -TERM "$terminate_pid" 2>/dev/null || true
  if ! wait_pid_until "$terminate_pid" "$terminate_grace"; then
    kill -KILL "$terminate_pid" 2>/dev/null || true
    wait "$terminate_pid" 2>/dev/null || true
  fi
}
wait_ssh() {
  deadline=$(perl -MTime::HiRes=time -e 'printf "%.6f\n", time + $ARGV[0]' "$TIMEOUT")
  while :; do
    if "$CLI" ssh --state-dir "$STATE_DIR" -- -o BatchMode=yes -- true >/dev/null 2>&1; then return 0; fi
    if [ -f "$START_STATUS" ]; then
      wait "$START_PID" 2>/dev/null || true
      START_PID=
      echo 'VM start process exited before SSH became ready; start log follows:' >&2
      if [ -s "$START_LOG" ]; then
        cat "$START_LOG" >&2
      else
        echo '(start log is empty)' >&2
      fi
      return 1
    fi
    perl -MTime::HiRes=time -e 'exit(time < $ARGV[0] ? 0 : 1)' "$deadline" || return 1
    sleep 1
  done
}
start_vm() {
  : > "$START_LOG"
  rm -f "$START_STATUS"
  (
    if "$CLI" start --kernel "$KERNEL" --initrd "$INITRD" --system "$SYSTEM" --state-dir "$STATE_DIR" \
      --cores "$CORES" --memory "$MEMORY" --disk-size "$DISK_SIZE" >"$START_LOG" 2>&1; then
      start_result=0
    else
      start_result=$?
    fi
    printf '%s\n' "$start_result" > "$START_STATUS.tmp"
    mv "$START_STATUS.tmp" "$START_STATUS"
    exit "$start_result"
  ) &
  START_PID=$!
}
stop_vm() {
  "$CLI" stop --state-dir "$STATE_DIR" >/dev/null 2>&1 &
  STOP_PID=$!
  if wait_pid_until "$STOP_PID" "$TIMEOUT"; then result=0; else result=1; terminate_and_wait "$STOP_PID" 5; fi
  STOP_PID=
  if [ -n "$START_PID" ]; then
    if [ -f "$START_STATUS" ]; then
      wait "$START_PID" 2>/dev/null || result=1
    elif ! wait_pid_until "$START_PID" "$TIMEOUT"; then
      result=1
      terminate_and_wait "$START_PID" 5
    fi
  fi
  START_PID=
  return "$result"
}

REVISION=$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || printf unknown)
CLI_SHA256=$(nix hash file --type sha256 "$CLI")
GUEST_ARTIFACT_SHA256=$(nix hash path --type sha256 "$KERNEL" "$INITRD" "$SYSTEM" | perl -MDigest::SHA=sha256_hex -e 'print sha256_hex(join "\n", sort <STDIN>)')
NIX_VERSION=$(nix --version)
MACOS_VERSION=$(sw_vers -productVersion)
HARDWARE_MODEL=$(sysctl -n hw.model)
perl -MJSON::PP -e '
  print JSON::PP->new->canonical->encode({
    iterations=>0+$ARGV[0], cores=>0+$ARGV[1], memory_mb=>0+$ARGV[2], disk_size=>$ARGV[3],
    timeout_seconds=>0+$ARGV[4], workload_label=>"representative_nix_build",
    host_arch=>$ARGV[5], macos_version=>$ARGV[6], revision=>$ARGV[7], cli_sha256=>$ARGV[8],
    guest_artifact_sha256=>$ARGV[9], nix_version=>$ARGV[10], hardware_model=>$ARGV[11],
    cold_definition=>"fresh harness-owned state directory",
    warm_definition=>"same persistent disk after graceful shutdown",
  })' "$ITERATIONS" "$CORES" "$MEMORY" "$DISK_SIZE" "$TIMEOUT" "$(uname -m)" "$MACOS_VERSION" "$REVISION" "$CLI_SHA256" "$GUEST_ARTIFACT_SHA256" "$NIX_VERSION" "$HARDWARE_MODEL" > "$METADATA"

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  rm -rf "$STATE_DIR"
  begin=$(now); start_vm
  if wait_ssh; then ok=1; else ok=0; fi
  ready=$(now); record "$i" cold_boot "$(elapsed "$begin" "$ready")" "$ok" "$([ "$ok" -eq 1 ] && printf success || printf failure)"
  record "$i" ssh_ready "$(elapsed "$begin" "$ready")" "$ok" "$([ "$ok" -eq 1 ] && printf success || printf failure)"
  cold_ok=$ok
  if [ "$cold_ok" -eq 1 ] && [ "$i" -le "$WORKLOAD_ITERATIONS" ]; then
    begin=$(now)
    if "$CLI" ssh --state-dir "$STATE_DIR" -- sh -lc "$WORKLOAD" >/dev/null 2>&1; then ok=1; else ok=0; fi
    finish=$(now); record "$i" build_workload "$(elapsed "$begin" "$finish")" "$ok" "$([ "$ok" -eq 1 ] && printf success || printf failure)"
  elif [ "$i" -le "$WORKLOAD_ITERATIONS" ]; then record "$i" build_workload 0 0 prerequisite_failure; fi
  begin=$(now); if stop_vm; then ok=1; else ok=0; fi; finish=$(now)
  record "$i" shutdown "$(elapsed "$begin" "$finish")" "$ok" "$([ "$ok" -eq 1 ] && printf success || printf failure)"
  shutdown_ok=$ok

  if [ "$cold_ok" -eq 1 ] && [ "$shutdown_ok" -eq 1 ]; then
    begin=$(now); start_vm
    if wait_ssh; then ok=1; else ok=0; fi
    finish=$(now); record "$i" warm_boot "$(elapsed "$begin" "$finish")" "$ok" "$([ "$ok" -eq 1 ] && printf success || printf failure)"
    stop_vm || true
  else
    record "$i" warm_boot 0 0 prerequisite_failure
  fi
  i=$((i + 1))
done

perl "$SCRIPT_DIR/benchmark-report.pl" collect "$SAMPLES" "$METADATA" "$OUTPUT"
printf 'wrote %s\n' "$OUTPUT"
