#!/bin/zsh -f
# sbrun.sh <project> <cmd...>: run <cmd> under probe.sb with a FAKE home ($SPIKE/home), print the tagged denials.
# Needs SPIKE (temp root, from setup.sh). GITCOMMON defaults to <project>/.git.
here=${0:A:h}; proj=${1:A}; shift
R() { python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }
home=$(R $SPIKE/home); proj=$(R $proj); gc=$(R ${GITCOMMON:-$proj/.git})
tag="collie-term:spike$$"
log=$SPIKE/deny.$$.ndjson
/usr/bin/log stream --style ndjson --predicate "sender == \"Sandbox\" AND eventMessage CONTAINS \"$tag\"" >$log 2>/dev/null &
lp=$!; sleep 2
( cd $proj && HOME=$home CFFIXED_USER_HOME=$home /usr/bin/sandbox-exec -f $here/probe.sb \
    -D HOME=$home -D PROJECT=$proj -D GITCOMMON=$gc -D TMP=$(R $(getconf DARWIN_USER_TEMP_DIR)) \
    -D CACHE=$(R $(getconf DARWIN_USER_CACHE_DIR)) -D COLLIE=$(R $SPIKE/collie) -D SOCK=$(R $SPIKE/collie)/daemon.sock \
    -D TAG=$tag "$@" )
rc=$?; sleep 3; kill $lp
echo "== rc=$rc denials:"
python3 -c '
import json,sys
seen=set()
for l in open(sys.argv[1]):
    try: m=json.loads(l)["eventMessage"].split("\n")[0]
    except Exception: continue
    m=m.split(") ",1)[-1] if "Sandbox:" in m else m
    if m not in seen: seen.add(m); print("  ",m)
' $log
exit $rc
