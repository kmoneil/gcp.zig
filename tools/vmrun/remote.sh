#!/bin/bash
# The VM side of tools/vmrun/vmrun: the startup script a new VM runs at
# boot. It reads the run from the instance's metadata, installs Zig
# (pinned and checked), unpacks the tree, runs the job, uploads
# /opt/vmrun/results to the run's bucket (results/exit last, which is
# what the driver waits for), and powers off.
set -u
MD=http://metadata.google.internal/computeMetadata/v1
md() { curl -sf -H "Metadata-Flavor: Google" "$MD/instance/attributes/$1"; }
BK=$(md bucket)
tok() { curl -s -H "Metadata-Flavor: Google" "$MD/instance/service-accounts/default/token" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p'; }
get() { curl -sf -H "Authorization: Bearer $(tok)" -o "$2" "https://storage.googleapis.com/storage/v1/b/$BK/o/${1//\//%2F}?alt=media"; }
put() { curl -sf -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" --data-binary "@$2" "https://storage.googleapis.com/upload/storage/v1/b/$BK/o?uploadType=media&name=${1//\//%2F}" > /dev/null; }

W=/opt/vmrun
RES=$W/results
mkdir -p "$RES"
cd "$W"
export HOME=/root DEBIAN_FRONTEND=noninteractive
exec > >(tee -a "$RES/boot.log") 2>&1
T0=$(date +%s)

stage() {
  echo "[$(( $(date +%s) - T0 ))s] $1" >> "$RES/stages"
  printf '%s\n' "$1" > "$W/stage"
  put results/stage "$W/stage" || true
}
finish() {
  (cd "$RES" && find . -type f ! -name exit) | while read -r f; do put "results/${f#./}" "$RES/${f#./}" || true; done
  put results/exit "$RES/exit"
  sync
  poweroff
  exit 0
}
fail() {
  echo "vmrun: $1"
  echo 125 > "$RES/exit"
  finish
}

JOB=$(md job)
ZIG_VERSION=$(md zig-version)
ZIG_SHA=$(md zig-sha256)
ARGS=()
while IFS= read -r a; do [ -n "$a" ] && ARGS+=("$a"); done < <(md job-args || true)

{ uname -a; nproc; free -h | head -2; . /etc/os-release && echo "$PRETTY_NAME"; } > "$RES/info.txt"

stage "installing"
apt-get update -q > "$RES/apt.log" 2>&1 && apt-get install -y -q xz-utils >> "$RES/apt.log" 2>&1 || fail "apt-get install xz-utils failed (results/apt.log)"

pin() { # url, sha256, file
  curl -sfL -o "$3" "$1" || fail "download $1 failed"
  echo "$2  $3" | sha256sum -c --quiet || fail "$1 does not have the pinned SHA-256"
}

stage "zig $ZIG_VERSION"
pin "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" "$ZIG_SHA" zig.tar.xz
tar xf zig.tar.xz
export PATH=$W/zig-x86_64-linux-$ZIG_VERSION:$PATH

stage "unpacking"
mkdir -p src
get src.tgz src.tgz || fail "no src.tgz in the bucket"
tar xzf src.tgz -C src || fail "src.tgz does not unpack"

stage "running $JOB${ARGS[*]:+ ${ARGS[*]}}"
zig version >> "$RES/info.txt"
# The Unix time the VM deletes itself at (its maxRunDuration counts
# from boot, close enough to this script's start). A job that watches
# it can stop cleanly and still get its results uploaded.
DEADLINE=$((T0 + $(md timeout-seconds)))

# job.log goes to the bucket each minute while the job runs, so even a
# VM that dies at its wall leaves the log behind for the driver to
# salvage.
: > "$RES/job.log"
( while sleep 60; do put results/job.log "$RES/job.log" || true; done ) &
SYNC=$!

# The backstop: whatever the job is doing, it is cut 150 seconds before
# the wall (a cooperating job stops on VMRUN_DEADLINE well before), so
# the uploads below always happen. A cut job exits 124 (137 if the TERM
# did not take).
BUDGET=$((DEADLINE - $(date +%s) - 150))
[ "$BUDGET" -ge 60 ] || BUDGET=60
JS=$(date +%s)
(cd src && RESULTS=$RES VMRUN_DEADLINE=$DEADLINE timeout -k 30 "$BUDGET" bash "$JOB" "${ARGS[@]}") > "$RES/job.log" 2>&1
S=$?
kill "$SYNC" 2> /dev/null
# A job can exit 124 on its own (fuzz.sh cuts a round with timeout
# too); only elapsed time tells whether this backstop was the cutter.
if { [ "$S" -eq 124 ] || [ "$S" -eq 137 ]; } && [ $(($(date +%s) - JS)) -ge "$BUDGET" ]; then
  echo "vmrun: the job was still running 150s before the VM's wall and was cut (exit $S)" >> "$RES/job.log"
fi
echo "$S" > "$RES/exit"
stage "done, exit $S"
finish
