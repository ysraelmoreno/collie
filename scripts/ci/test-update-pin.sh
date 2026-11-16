#!/bin/bash
# Offline check of scripts/ci/update-pin.sh on copies of Resources/figcraft-engine.json. Run: scripts/ci/test-update-pin.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
U=scripts/ci/update-pin.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ZERO=0000000000000000000000000000000000000000000000000000000000000000
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq --indent 2 '.version = "9.9.9-c1" | .sha256 = "'$ZERO'" | .size = 0 | .unpackedSize = 0' Resources/figcraft-engine.json > "$T/zero.json"
V=9.9.9-c1

# zeroed pin → new values; other fields and format kept
cp "$T/zero.json" "$T/p.json"
[ "$($U "$T/p.json" $V $A 123 456)" = changed ] || fail "zeroed: not changed"
[ "$(jq -r '"\(.sha256) \(.size) \(.unpackedSize)"' "$T/p.json")" = "$A 123 456" ] || fail "zeroed: values"
[ "$(jq -S 'del(.sha256, .size, .unpackedSize)' "$T/p.json")" = "$(jq -S 'del(.sha256, .size, .unpackedSize)' "$T/zero.json")" ] || fail "other fields changed"
diff <(sed -E 's/"(sha256|size|unpackedSize)": .*//' "$T/zero.json") <(sed -E 's/"(sha256|size|unpackedSize)": .*//' "$T/p.json") >/dev/null || fail "format changed"
[ "$(jq -r 'keys_unsorted | join(",")' "$T/p.json")" = "$(jq -r 'keys_unsorted | join(",")' "$T/zero.json")" ] || fail "key order"

# same values → no change, file untouched
cp "$T/p.json" "$T/before.json"
[ "$($U "$T/p.json" $V $A 123 456)" = unchanged ] || fail "same: not unchanged"
cmp -s "$T/p.json" "$T/before.json" || fail "same: file rewritten"

# filled pin, other values → refused (exit 3), file untouched
set +e; $U "$T/p.json" $V $B 124 457 >/dev/null 2>"$T/err"; rc=$?; set -e
[ "$rc" = 3 ] || fail "differs: exit $rc, want 3"
grep -q "not overwriting" "$T/err" || fail "differs: no message"
cmp -s "$T/p.json" "$T/before.json" || fail "differs: file changed"

# … unless the version was published just now (--fresh)
[ "$($U "$T/p.json" $V $B 124 457 --fresh 2>/dev/null)" = changed ] || fail "fresh: not changed"
[ "$(jq -r .sha256 "$T/p.json")" = "$B" ] || fail "fresh: value"

# another version, bad values → exit 1
set +e
$U "$T/zero.json" 9.9.9-c2 $A 1 1 >/dev/null 2>&1; [ $? = 1 ] || fail "other version accepted"
$U "$T/zero.json" $V "$ZERO" 1 1 >/dev/null 2>&1; [ $? = 1 ] || fail "zero sha accepted"
$U "$T/zero.json" $V $A 0 1 >/dev/null 2>&1; [ $? = 1 ] || fail "size 0 accepted"
$U "$T/zero.json" $V "$A; rm" 1 1 >/dev/null 2>&1; [ $? = 1 ] || fail "bad sha accepted"
set -e
echo "ok: update-pin.sh"
