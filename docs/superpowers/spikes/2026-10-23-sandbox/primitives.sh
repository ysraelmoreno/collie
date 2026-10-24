#!/bin/zsh -f
# primitives.sh: Step 1/3/4 SBPL primitive checks with inline profiles in a temp dir (no real home paths).
T=$(mktemp -d /tmp/sbprim.XXXX); T=${T:A}; cd $T; mkdir -p h/Documents h/.ssh; echo s >h/Documents/a; echo k >h/.ssh/id_x
p() { print -r -- "(version 1)(allow default)$1" }
echo "-- params + string-append + regex"
sandbox-exec -p "$(p '(define h (param "H"))(deny file-read* (subpath (string-append h "/Documents")))(deny file-read* (regex (string-append "^" h "/\\.ssh/id_")))')" -D H=$T/h \
  /bin/sh -c "cat $T/h/Documents/a; cat $T/h/.ssh/id_x" 2>&1
echo "-- unresolved /tmp path in a rule does not match (/private/tmp is the vnode path)"
sandbox-exec -p "$(p "(deny file-read* (subpath \"${T#/private}/h\"))")" cat ${T#/private}/h/Documents/a && echo "  read went through"
echo "-- signals (outside pid gets SIGCONT)"; sleep 60 & o=$!
for r in '(deny signal (target others))' '(deny signal)(allow signal (target same-sandbox))'; do
  sandbox-exec -p "$(p $r)" /bin/sh -c "kill -CONT $o 2>/dev/null && echo '  $r: outside signalled' || echo '  $r: outside denied'; sleep 9 & kill \$! && echo '  own child ok'"
done; kill $o
echo "-- setuid exec inside any sandbox"; sandbox-exec -p "$(p '')" /bin/ps -p $$ >/dev/null 2>&1 || echo "  /bin/ps denied"
sandbox-exec -p "$(p '(allow process-exec (literal "/bin/ps") (with no-sandbox))')" /bin/ps -p $$ >/dev/null && echo "  /bin/ps ok with (with no-sandbox)"
echo "-- nesting"; sandbox-exec -p "$(p '')" sandbox-exec -p "$(p '')" /usr/bin/true
echo "-- (with message) tag + (with no-log), watch: log stream --predicate 'eventMessage CONTAINS \"collie-term:\"'"
/usr/bin/log stream --style ndjson --predicate "sender == \"Sandbox\" AND eventMessage CONTAINS \"$T\"" >log.ndjson 2>/dev/null & l=$!; sleep 2
sandbox-exec -p "$(p "(deny file-read* (with no-log) (literal \"$T/h\"))(deny file-read* (with message \"collie-term:P\") (subpath \"$T/h/Documents\"))")" /bin/sh -c "ls $T/h; cat $T/h/Documents/a" 2>/dev/null
sleep 3; kill $l; /usr/bin/grep -o '"eventMessage":"[^"]*"' log.ndjson
rm -rf $T
