#!/bin/bash
# vmrun: machine=e2-standard-4 timeout=45
#
# The metadata server's keys, on the VM vmrun makes: the gated suite
# tests/auth_metadata_gcp_integration.zig (AUTH_TEST_METADATA=1), then
# examples/spot_worker.zig watching instance/preempted for up to
# WATCH_SECONDS (900 unless given) while tools/vmrun/metadata-test
# preempts the VM, whether or not the suite passed. The worker's log
# goes to the run's bucket the moment it says it was preempted, since a
# preempted VM's minute sync may not come.
#
#   tools/vmrun/vmrun tools/vmrun/jobs/metadata.sh
set -u
WATCH_SECONDS=${1:-900}
F="Metadata-Flavor: Google"
MD=http://metadata.google.internal/computeMetadata/v1
BK=$(curl -sf -H "$F" "$MD/instance/attributes/bucket")
tok() { curl -s -H "$F" "$MD/instance/service-accounts/default/token" | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p'; }
put() { curl -sf -X POST -H "Authorization: Bearer $(tok)" -H "Content-Type: application/octet-stream" --data-binary "@$2" "https://storage.googleapis.com/upload/storage/v1/b/$BK/o?uploadType=media&name=${1//\//%2F}" > /dev/null; }
# What vmrun prints as the run's stage.
stage() { printf '%s\n' "$1" > "$RESULTS/stage.txt"; put results/stage "$RESULTS/stage.txt" || true; }

stage "the gated suite"
AUTH_TEST_METADATA=1 zig build test-integration-gcp -Dtest-filter="metadata: " > "$RESULTS/suite.log" 2>&1
status=$?
echo "$status" > "$RESULTS/suite.exit"
put results/suite.log "$RESULTS/suite.log" || true
put results/suite.exit "$RESULTS/suite.exit" || true
grep -E '^(agree|DIFFER|  server|  fake|zone|job|a watch|[0-9]+ of)' "$RESULTS/suite.log" || true
# A failed suite still goes on to the preemption, so one run has both;
# the job's exit is the suite's then.
if [ "$status" != 0 ]; then
  tail -40 "$RESULTS/suite.log"
  echo "the gated suite failed ($status); watching for preemption all the same"
fi

stage "building the worker"
zig build example-spot_worker -- --fake > "$RESULTS/worker-fake.log" 2>&1 || { cat "$RESULTS/worker-fake.log"; exit 1; }
cat "$RESULTS/worker-fake.log"
L=$RESULTS/worker.log
zig build example-spot_worker > "$L" 2>&1 &
worker=$!
for _ in $(seq 1 600); do
  grep -q 'working until' "$L" && break
  kill -0 "$worker" 2> /dev/null || { cat "$L"; echo "the worker stopped before it was watching"; exit 1; }
  sleep 0.2
done
cat "$L"
stage "watching for preemption"
end=$(( $(date +%s) + WATCH_SECONDS ))
while [ "$(date +%s)" -lt "$end" ]; do
  if grep -q 'preempted at' "$L"; then
    echo "the job saw it at $(date +%s.%3N)" >> "$L"
    put results/worker.log "$L" || true
    cat "$L"
    wait "$worker"
    w=$?
    [ "$status" = 0 ] || exit "$status"
    exit "$w"
  fi
  kill -0 "$worker" 2> /dev/null || { cat "$L"; echo "the worker stopped without saying it was preempted"; exit 1; }
  sleep 0.2
done
kill "$worker" 2> /dev/null
echo "no preemption within $WATCH_SECONDS s"
exit 1
