#!/bin/bash
# vmrun: machine=e2-standard-2 timeout=30
#
# Sleeps SECONDS (900 unless given) and exits 0: a job that runs long
# enough for something to happen to its VM. tools/vmrun/preempt-test
# preempts it.
#
#   tools/vmrun/vmrun tools/vmrun/jobs/sleep.sh 600
set -eu
echo "sleeping ${1:-900}s"
sleep "${1:-900}"
