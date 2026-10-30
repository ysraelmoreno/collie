#!/system/bin/sh
# Runs ON the device as root (pushed by ca.sh). usage: ca-device.sh inject <hash>.0 | eject
# inject: tmpfs over /system/etc/security/cacerts with the current CAs + ours; on Android 14+ (APEX conscrypt) the same
# dir is bind-mounted over /apex/com.android.conscrypt/cacerts inside zygote's mount namespace and every running app's.
# eject: unmounts exactly the layers inject added (one per namespace), so whatever was there before comes back.
set -e
SYS=/system/etc/security/cacerts; APEX=/apex/com.android.conscrypt/cacerts; STAGE=/data/local/tmp/collie-ca
# short-lived processes may exit between listing and nsenter: their errors are dropped
pids() { for z in $(pidof zygote zygote64); do echo $z; ps -A -o PID,PPID | awk -v z=$z '$2==z{print $1}'; done; }
case $1 in
inject)
  [ -f "$STAGE/$2" ] || { echo "missing $STAGE/$2" >&2; exit 2; }
  src=$SYS; [ -d $APEX ] && src=$APEX
  rm -rf $STAGE/all && mkdir -p $STAGE/all && cp $src/* $STAGE/all/ && cp "$STAGE/$2" $STAGE/all/
  mount -t tmpfs collie-ca $SYS
  cp $STAGE/all/* $SYS/ && chown root:root $SYS/* && chmod 644 $SYS/* && chcon u:object_r:system_file:s0 $SYS $SYS/*
  if [ -d $APEX ]; then
    for p in $(pids); do nsenter --mount=/proc/$p/ns/mnt -- mount --bind $SYS $APEX 2>/dev/null & done; wait
    echo "apex bind: $(pids | wc -l) namespaces"
  fi
  echo "injected $2: $(ls $SYS | wc -l) CAs" ;;
eject)
  if [ -d $APEX ]; then for p in $(pids); do nsenter --mount=/proc/$p/ns/mnt -- sh -c "mount | grep -q 'collie-ca on $APEX' && umount $APEX" 2>/dev/null & done; wait; fi
  mount | grep -q "collie-ca on $SYS" && umount $SYS
  rm -rf $STAGE; echo "ejected" ;;
esac
