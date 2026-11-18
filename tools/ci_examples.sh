#!/usr/bin/env bash
# The examples, run end to end against the emulators: what CI's Examples
# step runs, and what tools/local_ci.py runs on a Mac before a merge. Each
# emulator's address comes from the environment, as the examples read it:
#
#     PUBSUB_EMULATOR_HOST=127.0.0.1:8085 \
#     STORAGE_EMULATOR_HOST=http://127.0.0.1:4443 \
#     FIRESTORE_EMULATOR_HOST=127.0.0.1:8087 bash tools/ci_examples.sh
#
# Every emulator must be fresh: the checks below count what the examples
# leave behind (two cities in CA, 25 in Bob's account), so a second run
# against the same emulators fails. fake-gcs-server must have been started
# with -public-host naming STORAGE_EMULATOR_HOST's host and port, and with
# PUBSUB_EMULATOR_HOST naming the Pub/Sub emulator, for the signed URL and
# the bucket notification. Without all three set, an example could reach
# Google with whatever credentials this machine has, so it refuses.
set -euo pipefail

for name in PUBSUB_EMULATOR_HOST STORAGE_EMULATOR_HOST FIRESTORE_EMULATOR_HOST; do
  if [ -z "${!name:-}" ]; then
    echo "ci_examples: $name is not set; refusing to run the examples against Google" >&2
    exit 2
  fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

zig build example-worker
zig build example-publish -- orders 3
zig build example-publisher -- orders 500 4
zig build example-worker
# Acked from the handler, which prints what the server said. At
# least the two: the emulator can hold a fresh subscription's
# first messages back for a while, and hand them over here.
zig build example-publish -- orders 2
zig build example-worker -- orders orders-worker --confirm | tee "$work/confirm.log"
test "$(grep -c ': taken$' "$work/confirm.log")" -ge 2
# No emulator in this one: the library's own in-memory Pub/Sub.
zig build example-in_memory -- 300
# A file up and back down through gcs_cp, byte for byte, in
# chunks; up again through uploadParallel, which the emulator
# takes as one ordinary upload, and down in three 32 MiB ranges
# through downloadParallel; then refused overwrites, plain and
# parallel, and a create-only parallel upload of a new name; and
# a round trip with --resume, whose state files are gone once the
# copies are done.
curl -sf -X POST "$STORAGE_EMULATOR_HOST/storage/v1/b?project=test" \
  -H "Content-Type: application/json" -d '{"name":"zigps-examples"}' >/dev/null
head -c 75497472 /dev/urandom > "$work/src.bin"
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/copy.bin
zig build example-gcs_cp -- gs://zigps-examples/dir/copy.bin "$work/back.bin"
cmp "$work/src.bin" "$work/back.bin"
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/parallel.bin --parallel 4
zig build example-gcs_cp -- gs://zigps-examples/dir/parallel.bin "$work/back-parallel.bin" --parallel 4
cmp "$work/src.bin" "$work/back-parallel.bin"
if zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/copy.bin --no-clobber; then
  echo "--no-clobber replaced an existing object"
  exit 1
fi
if zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/copy.bin --no-clobber --parallel 4; then
  echo "--no-clobber --parallel replaced an existing object"
  exit 1
fi
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/created.bin --no-clobber --parallel 4
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/resumed.bin --resume "$work/up.state"
zig build example-gcs_cp -- gs://zigps-examples/dir/resumed.bin "$work/back-resumed.bin" --resume "$work/down.state" --parallel 4
cmp "$work/src.bin" "$work/back-resumed.bin"
test ! -e "$work/up.state" && test ! -e "$work/down.state"
# An object stored gzip-compressed: decompressed here, and kept as
# stored with --no-decompress, in one stream and in ranges, each
# checked against the stored checksum.
head -c 3000000 /dev/urandom | base64 > "$work/page.txt"
gzip -c -n "$work/page.txt" > "$work/page.txt.gz"
{ printf -- '--BB\r\nContent-Type: application/json\r\n\r\n{"name":"dir/page.txt","contentEncoding":"gzip","contentType":"text/plain"}\r\n--BB\r\nContent-Type: text/plain\r\n\r\n'
  cat "$work/page.txt.gz"; printf '\r\n--BB--\r\n'; } > "$work/upload.body"
curl -sf -X POST "$STORAGE_EMULATOR_HOST/upload/storage/v1/b/zigps-examples/o?uploadType=multipart" \
  -H "Content-Type: multipart/related; boundary=BB" --data-binary @"$work/upload.body" >/dev/null
zig build example-gcs_cp -- gs://zigps-examples/dir/page.txt "$work/page-back.txt"
cmp "$work/page.txt" "$work/page-back.txt"
zig build example-gcs_cp -- gs://zigps-examples/dir/page.txt "$work/page-back.txt.gz" --no-decompress
cmp "$work/page.txt.gz" "$work/page-back.txt.gz"
zig build example-gcs_cp -- gs://zigps-examples/dir/page.txt "$work/page-ranges.txt.gz" --no-decompress --parallel 4
cmp "$work/page.txt.gz" "$work/page-ranges.txt.gz"
# Compressed on the way up with -z: the object holds gzip that the
# system's gzip reads back, and comes down decompressed. A name -z
# does not list goes up as it is. -Z compresses whatever the name,
# with --resume, whose state is gone once the copy is done.
zig build example-gcs_cp -- "$work/page.txt" gs://zigps-examples/dir/zipped.txt -z log,txt
zig build example-gcs_cp -- gs://zigps-examples/dir/zipped.txt "$work/zipped-back.txt"
cmp "$work/page.txt" "$work/zipped-back.txt"
zig build example-gcs_cp -- gs://zigps-examples/dir/zipped.txt "$work/zipped-back.txt.gz" --no-decompress
gzip -dc "$work/zipped-back.txt.gz" | cmp - "$work/page.txt"
zig build example-gcs_cp -- "$work/page.txt" gs://zigps-examples/dir/unzipped.txt -z log
zig build example-gcs_cp -- gs://zigps-examples/dir/unzipped.txt "$work/unzipped-back.txt" --no-decompress
cmp "$work/page.txt" "$work/unzipped-back.txt"
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/zipped.bin -Z --resume "$work/zip.state"
zig build example-gcs_cp -- gs://zigps-examples/dir/zipped.bin "$work/zipped-back.bin"
cmp "$work/src.bin" "$work/zipped-back.bin"
test ! -e "$work/zip.state"
# Under a customer-supplied key read from a file, and billed to a
# project: the emulator takes both and checks neither, so this
# checks that they travel. A file that holds no key is refused.
head -c 32 /dev/urandom | base64 > "$work/key.b64"
zig build example-gcs_cp -- "$work/src.bin" gs://zigps-examples/dir/keyed.bin --encryption-key-file "$work/key.b64" --billing-project test --parallel 4
zig build example-gcs_cp -- gs://zigps-examples/dir/keyed.bin "$work/back-keyed.bin" --encryption-key-file "$work/key.b64" --billing-project test
cmp "$work/src.bin" "$work/back-keyed.bin"
zig build example-gcs_cp -- "$work/page.txt" gs://zigps-examples/dir/kms.txt --kms-key projects/p/locations/us/keyRings/r/cryptoKeys/k
if zig build example-gcs_cp -- "$work/page.txt" gs://zigps-examples/dir/bad-key.txt --encryption-key-file "$work/page.txt"; then
  echo "--encryption-key-file took a file that holds no key"
  exit 1
fi
# An HMAC key signs with no credentials at all. The emulator
# checks no signature, so this checks the URL is made, names the
# HMAC algorithm, and fetches the object. The key is made up.
url=$(GCS_HMAC_ACCESS_ID=GOOG1E-TEST-ONLY GCS_HMAC_SECRET=TEST_ONLY_not_a_real_secret_000000000000 \
  zig build example-gcs_sign -- gs://zigps-examples/dir/copy.bin | sed -n "s/^curl '\(.*\)'$/\1/p")
case "$url" in *X-Goog-Algorithm=GOOG4-HMAC-SHA256*) ;; *) echo "gcs_sign made no HMAC-signed URL"; exit 1 ;; esac
curl -sf "$url" -o "$work/hmac.bin"
cmp "$work/src.bin" "$work/hmac.bin"
# A bucket's notifications: gcs_notify sets them up, an upload
# under the prefix reaches the Pub/Sub emulator through
# fake-gcs-server, and gcs_notify watch prints it, decoded.
curl -sf -X POST "$STORAGE_EMULATOR_HOST/storage/v1/b?project=test" \
  -H "Content-Type: application/json" -d '{"name":"zigps-notify"}' >/dev/null
zig build example-gcs_notify -- setup zigps-notify test zigps-uploads --prefix incoming/
printf 'hello notifications\n' > "$work/notify.txt"
zig build example-gcs_cp -- "$work/notify.txt" gs://zigps-notify/incoming/hello.txt
timeout 120 zig build example-gcs_notify -- watch test zigps-uploads-watch --count 1 | tee "$work/notify.log"
grep -q "finalize gs://zigps-notify/incoming/hello.txt" "$work/notify.log"
# Documents through the firestore example: written, changed in
# part, listed, read back, and deleted, which a read then misses.
zig build example-firestore -- set cities/LA "name=Los Angeles" population=3900000 nickname=LA
zig build example-firestore -- update cities/LA population=4000000 --delete nickname
zig build example-firestore -- set cities/LA/landmarks/tower height=300.5
zig build example-firestore -- get cities/LA | tee "$work/firestore.log"
grep -q "population: 4000000" "$work/firestore.log"
if grep -q nickname "$work/firestore.log"; then
  echo "update kept a field it was told to delete"
  exit 1
fi
zig build example-firestore -- collections cities/LA | grep -qx landmarks
# A counter: an increment on the server, twice, and a read of two
# documents at once, one of them missing.
zig build example-firestore -- incr cities/LA visits 2
zig build example-firestore -- incr cities/LA visits 3 | grep -qx "visits is now 5"
zig build example-firestore -- getall cities/LA cities/NOPE | tee "$work/getall.log"
grep -q "visits: 5" "$work/getall.log"
grep -qx "cities/NOPE: missing" "$work/getall.log"
# Queries: the biggest two of three cities, and a count by state.
zig build example-firestore -- set cities/SF state=CA population=870000
zig build example-firestore -- set cities/NY state=NY population=8300000
zig build example-firestore -- update cities/LA state=CA
zig build example-firestore -- query cities population '>' 0 --order population:desc --limit 2 | tee "$work/query.log"
test "$(grep -c '^cities/' "$work/query.log")" = 2
head -1 "$work/query.log" | grep -qx "cities/NY"
zig build example-firestore -- count cities state == CA | grep -qx 2
# A transaction: 25 moved, then a move of more than is left refused.
zig build example-firestore -- set accounts/alice balance=100
zig build example-firestore -- transfer accounts/alice accounts/bob balance 25 | grep -qx "moved 25: accounts/alice now holds 75, accounts/bob 25"
if zig build example-firestore -- transfer accounts/alice accounts/bob balance 500; then
  echo "transfer moved more than there was"
  exit 1
fi
zig build example-firestore -- get accounts/bob | grep -q "balance: 25"
zig build example-firestore -- rm cities/LA
if zig build example-firestore -- get cities/LA; then
  echo "rm left the document"
  exit 1
fi
