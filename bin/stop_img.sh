#!/bin/bash
#
# set -x

# stop tinderbox chroot image/s
#

if [[ ! "$(whoami)" = "tinderbox" ]]; then
  echo " wrong user "
  exit 1
fi

if [[ $# -eq 0 ]]; then
  images=$(ls -d ~/run/* 2>/dev/null)
else
  images=""
  for mnt in ${@}
  do
    if [[ ! -d $mnt ]]; then
      i=$(ls -d ~/run/$mnt ~/img/$mnt ~/img?/$mnt 2>/dev/null | head -n 1)
      if [[ ! -d $mnt ]]; then
        echo "cannot guess the full path to $mnt"
        continue
      fi
    fi
    images="$images $mnt"
  done
fi

for mnt in $images
do
  echo -n "$(date) "

  if [[ -L $mnt && ! -e $mnt ]]; then
    echo "broken symlink: $mnt"
    continue
  fi

  if [[ ! -d $mnt ]]; then
    echo "not a valid dir: $mnt"
    continue
  fi

  if [[ ! -f $mnt/var/tmp/tb/LOCK ]]; then
    echo " not running: $mnt"
    continue
  fi

  if [[ -f $mnt/var/tmp/tb/STOP ]]; then
    echo " STOP marker already set: $mnt"
    continue
  fi

  echo " stopping     $mnt"
  touch $mnt/var/tmp/tb/STOP
done
