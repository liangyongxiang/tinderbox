#!/bin/bash
# set -x


function getCandidates()  {
  ls -d ~tinderbox/img/17.*-j*-20??????-?????? 2>/dev/null |\
  while read -r i
  do
    if [[ -e ~tinderbox/run/$(basename $i) ]]; then
      continue
    fi

    if __is_running $i; then
      continue
    fi

    if [[ $(( (EPOCHSECONDS-$(stat -c %Y $i))/86400 )) -lt 1 ]]; then
      continue
    fi

    if [[ -s $i/var/log/emerge.log ]]; then
      # keep images having emerge logs within last 2 weeks (for "whatsup.sh -e")
      if [[ $(( (EPOCHSECONDS-$(stat -c %Y $i/var/log/emerge.log))/86400 )) -le 14 ]]; then
        continue
      fi
    fi

    echo $i
  done |\
  sort -t'-' -k 3,4     # sort by date + time, oldest first
}


# $ df -m /dev/nvme0n1p4
# Filesystem     1M-blocks    Used Available Use% Mounted on
# /dev/nvme0n1p4   6800859 5989215    778178  89% /mnt/data
function pruneNeeded()  {
  local fs=/dev/nvme0n1p4
  local free=200000        # in GB
  local used=89            # in %

  [[ -n $(df -m $fs | awk ' $1 == "'"$fs"'" && ($4 < "'"$free"'" || $5 > "'"$used"'%")') ]]
}



function pruneDir() {
  local d=$1

  if [[ ! -d $d ]]; then
    echo "$d is not a dir !"
    exit 1
  fi

  # https://forums.gentoo.org/viewtopic-p-6072905.html?sid=461188c03d3c4d08de80136a49982d86#6072905
  if [[ -d $d/tmp/.private  ]]; then
    chattr -R -a $d/tmp/.private
  fi
  rm -r $d
  local rc=$?

  sleep 30    # lazy btrfs
  return $rc
}


#######################################################################
set -eu
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/tb/bin"
export LANG=C.utf8

if [[ "$(whoami)" != "root" ]]; then
  echo " you must be root"
  exit 1
fi

source $(dirname $0)/lib.sh

# prune old stage3 files
latest=~tinderbox/distfiles/latest-stage3.txt
if [[ -s $latest ]]; then
  ls ~tinderbox/distfiles/stage3-amd64-*.tar.xz 2>/dev/null |\
  while read -r stage3
  do
    if [[ $latest -nt $stage3 ]]; then
      if ! grep -q -F $(basename $stage3) $latest; then
        rm -f $stage3{,.asc}    # *.asc might not exist
      fi
    fi
  done
fi

# prune distfiles not accessed within last year
if pruneNeeded; then
  find ~tinderbox/distfiles/ -maxdepth 1 -type f -atime +365 -delete
fi

# prune images with broken setup
while read -r img && pruneNeeded
do
  if [[ ! -s $img/var/log/emerge.log || ! -d $img/var/tmp/tb ]]; then
    pruneDir $img
  fi
done < <(getCandidates)

# prune images w/o any reported bug
while read -r img && pruneNeeded
do
  if ! ls $img/var/tmp/tb/issues/*/.reported &>/dev/null; then
    pruneDir $img
  fi
done < <(getCandidates)

# prune old images
while read -r img && pruneNeeded
do
  pruneDir $img
done < <(getCandidates)
