#!/system/bin/sh
# Runs ON the device as root; pushed to /data/local/tmp/collie-ca/ by netsetup.sh. Reference for DeviceSetup (Swift).
#
#   netsetup-device.sh inject <hash>   CA staged at $ST/<hash>.0 → system store (+ APEX on 14+) and user store
#   netsetup-device.sh eject           undo exactly what inject added
#   netsetup-device.sh status          one line per store
#
# Every step is idempotent: a layer is added only where it is missing and removed only where it is ours. Our tmpfs is
# mounted with source name "collie-ca", so "collie-ca <dir> tmpfs" in a namespace's /proc/self/mounts marks our layer.
# Output is "key: value" lines (parsed by netsetup.sh, and later by DeviceSetup).
set -u
SYS=/system/etc/security/cacerts             # system store, Android ≤13 (still present on 14+, unused by conscrypt)
APEX=/apex/com.android.conscrypt/cacerts     # system store read by conscrypt on Android 14+ (immutable APEX)
USR=/data/misc/user/0/cacerts-added          # user store: Chrome (Chrome Root Store) trusts only this one + its own
ST=/data/local/tmp/collie-ca                 # staging: our CA, this script, markers (survives reboot; tmpfs does not)

ours() { grep -q "^collie-ca $1 " "${2:-/proc/self/mounts}"; }
# Mount namespaces to patch on 14+: every zygote (zygote, zygote64, webview_zygote, *_app_zygote) and their children.
# New apps fork from a zygote and inherit its mounts; running ones need their own bind. Processes may exit between
# listing and nsenter: those are counted as "gone", not errors.
targets() {
  ps -A -o PID,PPID,NAME | awk 'NR>1 { pid[NR]=$1; ppid[NR]=$2; if ($3 ~ /zygote/) z[$1]=1 }
    END { for (i in pid) if ((pid[i] in z) || (ppid[i] in z)) print pid[i] }'
}

case ${1:-} in
inject)
  H=$2; [ -f "$ST/$H.0" ] || { echo "error: missing $ST/$H.0"; exit 2; }
  # 1. system store: tmpfs over $SYS holding the current CAs + ours (copied from APEX on 14+, it is the live set there)
  if ours $SYS; then
    [ -f "$SYS/$H.0" ] || cp "$ST/$H.0" $SYS/   # rotated CA: add it to the existing layer
    echo "system: present"
  else
    src=$SYS; [ -d $APEX ] && src=$APEX
    rm -rf $ST/all && mkdir -p $ST/all && cp $src/* $ST/all/ && cp "$ST/$H.0" $ST/all/
    mount -t tmpfs -o mode=755 collie-ca $SYS || { echo "error: tmpfs mount failed"; exit 1; }
    cp $ST/all/* $SYS/ && rm -rf $ST/all
    chown root:root $SYS/* && chmod 644 $SYS/* && chcon u:object_r:system_file:s0 $SYS $SYS/*
    echo "system: mounted $(ls $SYS | wc -l) CAs"
  fi
  # 2. Android 14+: bind $SYS over $APEX in each zygote/app namespace that lacks it (parallel: ~1 s for ~60 namespaces)
  if [ -d $APEX ]; then
    : > $ST/apex.out
    for p in $(targets); do (
      if [ ! -e /proc/$p/ns/mnt ]; then echo gone
      elif nsenter --mount=/proc/$p/ns/mnt -- sh -c "grep -q '^collie-ca $APEX ' /proc/self/mounts"; then echo already
      elif nsenter --mount=/proc/$p/ns/mnt -- mount --bind $SYS $APEX 2>/dev/null; then echo bound
      else echo gone; fi ) >> $ST/apex.out &
    done; wait
    echo "apex: $(grep -c bound $ST/apex.out) bound, $(grep -c already $ST/apex.out) already, $(grep -c gone $ST/apex.out) gone"
    rm -f $ST/apex.out
  else
    echo "apex: none (Android ≤13)"
  fi
  # 3. user store (Chrome). Remember whether we added it, so eject never removes a CA the user installed themselves.
  if [ -f "$USR/$H.0" ]; then
    [ -f $ST/user-added ] && echo "user: present" || echo "user: preexisting (left alone)"
  else
    mkdir -p $USR && chown system:system $USR && chmod 755 $USR
    cp "$ST/$H.0" $USR/ && chown system:system "$USR/$H.0" && chmod 644 "$USR/$H.0" && chcon u:object_r:misc_user_data_file:s0 $USR "$USR/$H.0"
    echo "$H" > $ST/user-added; echo "user: added"
  fi
  echo "$H" > $ST/hash ;;
eject)
  # reverse order: app/zygote binds, the system tmpfs, the user-store file we added, the staging dir
  if [ -d $APEX ]; then
    n=0; for p in $(targets); do
      [ -e /proc/$p/ns/mnt ] && nsenter --mount=/proc/$p/ns/mnt -- sh -c "grep -q '^collie-ca $APEX ' /proc/self/mounts && umount $APEX" 2>/dev/null && n=$((n+1))
    done; echo "apex: $n unbound"
  fi
  if ours $SYS; then umount $SYS && echo "system: unmounted"; else echo "system: absent"; fi
  if [ -f $ST/user-added ]; then rm -f "$USR/$(cat $ST/user-added).0"; echo "user: removed"; else echo "user: untouched"; fi
  rm -rf $ST; echo "ejected" ;;
status)
  H=$(cat $ST/hash 2>/dev/null || echo none)
  ours $SYS && echo "system: layer ($(ls $SYS | wc -l) CAs, ours=$([ -f $SYS/$H.0 ] && echo yes || echo no))" || echo "system: stock"
  if [ -d $APEX ]; then
    b=0; t=0; for p in $(targets); do t=$((t+1)); ours $APEX /proc/$p/mounts 2>/dev/null && b=$((b+1)); done
    echo "apex: $b/$t namespaces"
  fi
  [ -f "$USR/$H.0" ] && echo "user: present" || echo "user: absent"
  echo "hash: $H" ;;
*) echo "usage: $0 inject <hash> | eject | status"; exit 2 ;;
esac
