#!/bin/bash
# vmrun: machine=e2-standard-8 timeout=180
#
# A long fuzz campaign on a Linux spot VM: the nightly's fuzz jobs (the
# matrix in .github/workflows/ci.yml, read from there), one lane per
# core, each lane fuzzing its jobs in rounds until the VM's deadline
# nears. Losing a campaign to preemption costs only a rerun (vmrun exits
# 75); --on-demand opts out.
#
#   tools/vmrun/vmrun tools/vmrun/jobs/fuzz.sh                   # every job, 3h
#   tools/vmrun/vmrun tools/vmrun/jobs/fuzz.sh slow-subscriber   # one job on every core
#   tools/vmrun/vmrun --timeout 600 tools/vmrun/jobs/fuzz.sh core auth
#   tools/vmrun/jobs/fuzz.sh dry=1 slow-subscriber pubsub        # the plan, here
#
# Arguments are nightly job names (none: all of them) and settings:
#   share=N   a round fuzzes each job at 1/N of its nightly count (6; the
#             counts aim at about 90 minutes on a CI runner, so about 15)
#   stall=S   seconds a fuzzer may sit on one input before it is called
#             stalled (600; the slowest property takes about 40 s a run)
#   lanes=N   lanes (the VM's cores)
#   dry=1     print each lane's jobs and counts, and run nothing
#
# Lanes: `zig build --fuzz` runs one fuzzer process per test binary, and
# -Dmodule builds one, so a lane is a core. With at least as many jobs
# as lanes, lane L takes jobs L, L+lanes, and so on; with fewer, the
# jobs take the lanes in turn, so one job named runs on every core, each
# lane a fuzzer of its own with a corpus of its own.
#
# Rounds: Zig 0.17's fuzzer grows its memory for as long as one process
# runs, so each round is a fresh `zig build` that starts from the corpus
# the last one kept. A run starts only if half again its last time still
# fits before the deadline, and one still going 240 s before it is cut.
#
# Stalls: the Subscriber property stalled twice in the nightly, silent
# until the job's timeout. A fuzzer writes each input it runs into its
# in<N> file, so one that sits on the same input for `stall` seconds is
# stuck: every thread of every process in its run gets a gdb backtrace,
# its input is kept, and the run is killed.
#
# Results: lanes/<L>.log, one line a run with its peak memory; a
# failures/<lane>-<job>-r<round>/ for each input found or stall, with the
# run's output, the fuzzer's in<N> files (a 20-byte header: u64 pc
# digest, u32 instance, test index and length; then the input) and, for a
# stall, stacks.txt; corpus/<L>.tgz, each lane's grown corpus. A job that
# failed in a lane is not run there again. Any failure exits 1, once
# every lane has stopped.
#
# Seeds: tools/vmrun/fetch-seeds puts the newest corpus each nightly job
# kept on main into tools/vmrun/seeds.tgz, which vmrun ships; a lane
# starts from its jobs' corpora when it is there.
set -u

STALL=600 SHARE=6 LANES="" DRY=""
JOBS=()
for a in "$@"; do
  case $a in
    stall=*) STALL=${a#stall=} ;;
    share=*) SHARE=${a#share=} ;;
    lanes=*) LANES=${a#lanes=} ;;
    dry=*) DRY=${a#dry=} ;;
    *=*) echo "fuzz: unknown setting $a"; exit 2 ;;
    *) JOBS+=("$a") ;;
  esac
done

# The nightly's matrix, one job a line: job, module, filter, count.
MATRIX=$(awk '/^ *- \{ job: / {
  s = $0; sub(/^ *- \{ /, "", s); sub(/ \}$/, "", s)
  n = split(s, kv, ", ")
  split("", f)
  for (i = 1; i <= n; i++) { k = kv[i]; sub(/: .*/, "", k); v = kv[i]; sub(/^[a-z_]+: /, "", v); f[k] = v }
  print f["job"] "\t" f["module"] "\t" f["filter"] "\t" f["iterations"]
}' .github/workflows/ci.yml)
[ -n "$MATRIX" ] || { echo "fuzz: no fuzz matrix in .github/workflows/ci.yml"; exit 2; }
row() { awk -F '\t' -v j="$1" '$1 == j' <<< "$MATRIX"; }
if [ ${#JOBS[@]} -eq 0 ]; then
  while IFS=$'\t' read -r j _; do JOBS+=("$j"); done <<< "$MATRIX"
fi
for j in "${JOBS[@]}"; do
  [ -n "$(row "$j")" ] || { echo "fuzz: no nightly job $j; the jobs are $(cut -f1 <<< "$MATRIX" | tr '\n' ' ')"; exit 2; }
done

# A count as the matrix writes it (44K, 2M), as a number.
count() {
  case $1 in
    *K) echo $((${1%K} * 1000)) ;;
    *M) echo $((${1%M} * 1000000)) ;;
    *G) echo $((${1%G} * 1000000000)) ;;
    *) echo "$1" ;;
  esac
}
# A job's count for one round.
share() { local n; n=$(( $(count "$1") / SHARE )); [ "$n" -ge 1 ] || n=1; echo "$n"; }

[ -n "$LANES" ] || LANES=$(nproc 2> /dev/null || sysctl -n hw.ncpu)
declare -a LANE_JOBS
for ((l = 0; l < LANES; l++)); do LANE_JOBS[l]=""; done
if [ ${#JOBS[@]} -ge "$LANES" ]; then
  for i in "${!JOBS[@]}"; do l=$((i % LANES)); LANE_JOBS[l]+="${JOBS[i]} "; done
else
  for ((l = 0; l < LANES; l++)); do LANE_JOBS[l]=${JOBS[l % ${#JOBS[@]}]}; done
fi

if [ -n "$DRY" ]; then
  echo "fuzz: $LANES lane(s), a round at 1/$SHARE of each nightly count, stalled after ${STALL}s"
  for ((l = 0; l < LANES; l++)); do
    printf 'lane %d:' "$l"
    for j in ${LANE_JOBS[l]}; do IFS=$'\t' read -r _ m f c <<< "$(row "$j")"; printf ' %s (%s, "%s", %s)' "$j" "$m" "$f" "$(share "$c")"; done
    echo
  done
  exit 0
fi

[ "$(uname)" = Linux ] || { echo "fuzz: this job runs on a vmrun VM (Linux: /proc, setsid, gdb); dry=1 prints its plan anywhere"; exit 2; }
DEADLINE=${VMRUN_DEADLINE:?fuzz: no VMRUN_DEADLINE; run it through tools/vmrun/vmrun}
RESULTS=${RESULTS:?}
W=$(mktemp -d /var/tmp/fuzz.XXXXXX)
mkdir -p "$RESULTS/lanes" "$RESULTS/failures" "$RESULTS/corpus"
# The fuzzer panics without a tmp/ where it runs.
mkdir -p tmp
apt-get install -y -q gdb > "$RESULTS/gdb-apt.log" 2>&1 || echo "fuzz: gdb did not install (gdb-apt.log); a stall is kept without stacks"

filters_of() { # a filter of several names, separated by |, runs each of them
  local f
  FILTERS=()
  IFS='|' read -ra parts <<< "$1"
  for f in "${parts[@]}"; do FILTERS+=("-Dtest-filter=$f"); done
}

# Every job is built once before the lanes start, a lane's worth at a
# time, so a lane's own build is a hit in the shared global cache rather
# than eight LLVM builds of one test binary at once. (A test filter is
# compiled in, so each job is a build of its own: about 50 s and 600 MB
# cold on an M-series Mac.) Built and run as the unit tests do, so a job
# that does not pass on Linux is said here, and held to 30 minutes, so
# one that hangs there is too.
echo "fuzz: building $(printf '%s\n' "${JOBS[@]}" | sort -u | wc -l | tr -d ' ') job(s) $(date -u +%H:%M:%S)"
BROKEN=" "
building=0
for j in $(printf '%s\n' "${JOBS[@]}" | sort -u); do
  IFS=$'\t' read -r _ m f _ <<< "$(row "$j")"
  filters_of "$f"
  ( timeout -k 30 1800 zig build test-unit -Dfuzz-runner "-Dmodule=$m" "${FILTERS[@]}" --cache-dir "$W/warm-$j" > "$W/warm-$j.log" 2>&1 ||
      { echo "fuzz: $j does not build or pass (exit $?): $(tail -5 "$W/warm-$j.log")"; touch "$W/broken-$j"; } ) &
  building=$((building + 1))
  if [ "$building" -ge "$LANES" ]; then wait -n; building=$((building - 1)); fi
done
wait
for j in "${JOBS[@]}"; do [ ! -e "$W/broken-$j" ] || BROKEN="$BROKEN$j "; done
left=""
[ -z "${BROKEN// /}" ] || left="; left out:$BROKEN"
echo "fuzz: built $(date -u +%H:%M:%S)$left"

# Each run's process group, so the backstop's TERM can end them all.
on_term() {
  local g
  for g in "$W"/pgid-*; do [ -f "$g" ] && kill -KILL -- "-$(cat "$g")" 2> /dev/null; done
  echo "fuzz: cut by the VM's backstop; packing what the lanes have"
  pack
  exit 124
}
pack() {
  local l
  for ((l = 0; l < LANES; l++)); do
    [ -d "$W/lane-$l/f" ] && tar czf "$RESULTS/corpus/$l.tgz" -C "$W/lane-$l" --exclude='f/in*' --exclude='f/crash' f
  done
}

# Keeps a failure: the run's output, the fuzzer's inputs and what they
# hold, and the crash file when the fuzzer wrote one.
keep() { # dir, cache, output
  local f t n
  mkdir -p "$1"
  cp "$3" "$1/output.log"
  for f in "$2"/f/in* "$2"/f/crash; do
    [ -f "$f" ] || continue
    cp "$f" "$1/"
    case ${f##*/} in
      in*)
        t=$(od -A n -t u4 -j 12 -N 4 "$f" | tr -d ' ') n=$(od -A n -t u4 -j 16 -N 4 "$f" | tr -d ' ')
        echo "${f##*/}: fuzz test $t, $n bytes:" >> "$1/inputs.txt"
        od -A d -t x1 -j 20 -N "$n" "$f" >> "$1/inputs.txt" ;;
    esac
  done
}

# One job's run in a lane, in a session of its own. Sets RAN to how it
# ended: ok, found, stall, cut or "exit N".
run() { # lane, job, round, cache
  local l=$1 j=$2 r=$3 cache=$4 m f c n pid out t0 now s sum="" since peak=0 rss why=""
  IFS=$'\t' read -r _ m f c <<< "$(row "$j")"
  n=$(share "$c")
  filters_of "$f"
  out=$cache/run.log
  t0=$(date +%s) since=$t0
  setsid zig build test-unit -Dfuzz-runner "-Dmodule=$m" "${FILTERS[@]}" "--fuzz=$n" --cache-dir "$cache" > "$out" 2>&1 &
  pid=$!
  echo "$pid" > "$W/pgid-$l"
  while [ -d "/proc/$pid" ] && [ "$(ps -o stat= -p "$pid" | cut -c1)" != Z ]; do
    sleep 15
    now=$(date +%s)
    rss=$(ps -o rss= -p "$(pgrep -g "$pid" | paste -sd, -)" 2> /dev/null | awk '{ s += $1 } END { print s + 0 }')
    [ "$rss" -le "$peak" ] || peak=$rss
    if [ "$now" -ge $((DEADLINE - 240)) ]; then why=cut; break; fi
    s=$(cat "$cache"/f/in* 2> /dev/null | cksum)
    if [ "$s" != "$sum" ]; then sum=$s since=$now
    elif [ $((now - since)) -ge "$STALL" ]; then why=stall; break; fi
  done
  local d=$RESULTS/failures/$l-$j-r$r
  if [ "$why" = stall ]; then
    keep "$d" "$cache" "$out"
    for p in $(pgrep -g "$pid"); do
      echo "=== pid $p $(readlink "/proc/$p/exe"): $(tr '\0' ' ' < "/proc/$p/cmdline")"
      timeout 300 gdb -p "$p" -batch -nx -ex 'set pagination off' -ex 'info threads' -ex 'thread apply all bt' 2>&1
    done > "$d/stacks.txt"
  fi
  if [ -n "$why" ]; then
    kill -TERM -- "-$pid" 2> /dev/null; sleep 5; kill -KILL -- "-$pid" 2> /dev/null
  fi
  wait "$pid"; s=$?
  rm -f "$W/pgid-$l"
  if [ -n "$why" ]; then RAN=$why
  elif grep -q -E "input saved to|exited with code|terminated with signal" "$out"; then RAN=found; keep "$d" "$cache" "$out"
  elif [ "$s" -ne 0 ]; then RAN="exit $s"; keep "$d" "$cache" "$out"
  else RAN=ok; fi
  LAST=$(( $(date +%s) - t0 ))
  echo "$(date -u +%H:%M:%S) round $r $j: $n runs a property, ${LAST}s, peak $((peak / 1024)) MB: $RAN" >> "$RESULTS/lanes/$l.log"
}

lane() { # lane, its jobs
  local l=$1 cache=$W/lane-$1 r=1 j ran est left
  shift
  local -A last=() out=()
  mkdir -p "$cache/f" "$cache/tmp"
  for j in "$@"; do
    [ "${BROKEN/ $j /}" = "$BROKEN" ] || out[$j]=1
    # -m: an artifact's times come out hours off this clock, and tar
    # would warn about every file.
    if [ -f tools/vmrun/seeds.tgz ] && tar tzf tools/vmrun/seeds.tgz "$j/" > /dev/null 2>&1; then
      tar xzmf tools/vmrun/seeds.tgz -C "$cache/f" --strip-components=1 --exclude="$j/in*" --exclude="$j/crash" "$j/"
    fi
  done
  local why="nothing more fits before the deadline"
  while :; do
    ran="" left=""
    for j in "$@"; do
      [ -z "${out[$j]:-}" ] || continue
      left=1
      est=${last[$j]:-$((5400 / SHARE))}
      [ $(( $(date +%s) + est * 3 / 2 + 240 )) -le "$DEADLINE" ] || continue
      run "$l" "$j" "$r" "$cache"
      ran=1 last[$j]=$LAST
      case $RAN in ok|cut) ;; *) out[$j]=1 ;; esac
    done
    [ -n "$left" ] || why="each of its jobs failed or was left out"
    [ -n "$ran" ] || break
    r=$((r + 1))
  done
  echo "$(date -u +%H:%M:%S) lane $l stops: $why" >> "$RESULTS/lanes/$l.log"
}

trap on_term TERM
echo "fuzz: $LANES lane(s) until $(date -u -d "@$((DEADLINE - 240))" +%H:%M:%S), a round at 1/$SHARE of each nightly count, stalled after ${STALL}s"
for ((l = 0; l < LANES; l++)); do
  # shellcheck disable=SC2086 # a lane's jobs, one word each
  lane "$l" ${LANE_JOBS[l]} &
done
wait
pack

# What each lane did, and every failure.
for ((l = 0; l < LANES; l++)); do
  echo "lane $l: $(grep -c ' round ' "$RESULTS/lanes/$l.log" 2> /dev/null || echo 0) run(s); $(grep -v ': ok$' "$RESULTS/lanes/$l.log" | grep ' round ' | sed 's/^[0-9:]* //' | paste -sd ';' - || true)"
done
free -m | head -2
failures=$(command ls "$RESULTS/failures" | wc -l | tr -d ' ')
if [ "$failures" -gt 0 ]; then
  echo "fuzz: $failures failure(s): $(command ls "$RESULTS/failures" | tr '\n' ' ')"
  exit 1
fi
[ -z "${BROKEN// /}" ] || { echo "fuzz: left out, not building or passing:$BROKEN"; exit 1; }
echo "fuzz: nothing found"
