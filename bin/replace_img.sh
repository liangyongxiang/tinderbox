#!/bin/bash
# set -x

# replace an image with a new one


function Finish() {
  local rc=${1:-$?}
  local pid=$$

  trap - INT QUIT TERM EXIT

  if [[ $rc -ne 0 ]]; then
    echo
    date
    echo " pid $pid exited with rc=$rc"
  fi

  rm $lockfile
  exit $rc
}


function listImages() {
  (cd ~/run; ls -d * 2>/dev/null | shuf)
}


function GetCompletedEmergeOperations() {
  grep -c ' ::: completed emerge' ~/run/$1/var/log/emerge.log 2>/dev/null || echo "0"
}


function NumberOfPackagesInBacklog() {
  wc -l 2>/dev/null < ~/run/$1/var/tmp/tb/backlog || echo "0"
}


function NumberOfNewBugs() {
 ls ~/run/$1/var/tmp/tb/issues/*/.reported 2>/dev/null | wc -l || echo "0"
}


function HasAnEmptyBacklog() {
  while read -r i
  do
    local bl=~/run/$i/var/tmp/tb/backlog
    if [[ -f $bl ]]; then
      if [[ $(wc -l < $bl) -eq 0 ]]; then
        oldimg=$i
        return 0
      fi
    else
      echo "warn: $bl is missing !"
    fi
  done < <(listImages)

  return 1
}


function BrokenAndTooOldToRepair() {
  while read -r i
  do
    local days=$(( ( $(date +%s) - $(getStartTime $i) ) / 86400 ))
    if [[ $days -ge 3 ]]; then
      local p=$(tail -n 1 ~/run/$i/var/tmp/tb/@preserved-rebuild.history 2>/dev/null) || true
      local w=$(tail -n 1 ~/run/$i/var/tmp/tb/@world.history             2>/dev/null) || true
      if grep -q " NOT ok $" <<< $p || grep -q " NOT ok $" <<< $w ; then
        oldimg=$i
        return 0
      fi
    fi
  done < <(listImages)

  return 1
}


function MinDistanceIsReached() {
  # TODO: use name
  local newest=$(cd ~/run; ls -t */var/tmp/tb/name 2>/dev/null | cut -f1 -d'/' -s | head -n 1)
  if [[ -z "$newest" ]]; then
    return 1
  fi

  local distance=$(( ( $(date +%s) - $(getStartTime $newest) ) / 3600 ))
  [[ $distance -ge $condition_distance ]]
}


function FreeSlotAvailable() {
  if [[ ! $condition_count -gt -1 ]]; then
    return 1
  fi

  if ! pgrep -f $(dirname $0)/setup_img.sh 1>/dev/null; then
    [[ $(listImages | wc -l) -lt $condition_count && $(ls /run/tinderbox 2>/dev/null | wc -l) -lt $condition_count ]]
  fi
}


function ReplaceAnImage() {
  if [[ $condition_distance -gt -1 ]]; then
    if ! MinDistanceIsReached; then
      return 1
    fi
  fi

  while read -r i
  do
    if [[ $condition_runtime -gt -1 ]]; then
      local runtime=$(( ( $(date +%s) - $(getStartTime $i) ) / 3600 / 24))
      if [[ $runtime -ge $condition_runtime ]]; then
        reason="runtime >$condition_runtime days"
        oldimg=$i
        return 0
      fi
    fi
    if [[ $condition_left -gt -1 ]]; then
      if [[ $(NumberOfPackagesInBacklog $i) -le $condition_left ]]; then
        reason="backlog <$condition_left lines"
        oldimg=$i
        return 0
      fi
    fi
    if [[ $condition_completed -gt -1 ]]; then
      if [[ $(GetCompletedEmergeOperations $i) -ge $condition_completed ]]; then
        reason=">$condition_completed emerges completed"
        oldimg=$i
        return 0
      fi
    fi
    if [[ $condition_bugs -gt -1 ]]; then
      if [[ $(NumberOfNewBugs $i) -eq 0 && $(GetCompletedEmergeOperations $i) -ge $condition_bugs ]] ; then
        reason="no new bugs found in $condition_bugs emerges"
        oldimg=$i
        return 0
      fi
    fi
  done < <(listImages)

  return 1
}


function StopOldImage() {
  local msg="replace reason: $1"

  echo
  date
  echo " $msg for $oldimg"

  local lock_dir=/run/tinderbox/$oldimg.lock
  if [[ -d $lock_dir ]]; then
    date
    echo -e "\n waiting for image unlock ..."

    # do not just put a "STOP" into backlog.1st b/c job.sh might prepend additional task/s onto it
    # repeat STOP lines to neutralise an external triggered restart
    cat << EOF >> ~/run/$oldimg/var/tmp/tb/backlog.1st
STOP
STOP
STOP
STOP
STOP
STOP $msg
EOF
    echo "$msg" >> ~/run/$oldimg/var/tmp/tb/STOP
    local i=7200
    while [[ -d $lock_dir ]]
    do
      if ! ((--i)); then
        echo "give up on $oldimg"
        sed '/^STOP/d' ~/run/$oldimg/var/tmp/tb/backlog.1st
        rm ~/run/$oldimg/var/tmp/tb/STOP
        return 1
      fi
      sleep 1
    done
    echo "done"
  fi

  rm -- ~/run/$oldimg ~/logs/$oldimg.log
  oldimg=""
}


function setupANewImage() {
  echo
  date
  echo " setup a new image ..."
  sudo ${0%/*}/setup_img.sh $setupargs
}


#######################################################################
set -eu
export LANG=C.utf8

source $(dirname $0)/lib.sh

if [[ ! "$(whoami)" = "tinderbox" ]]; then
  echo " you must be tinderbox"
  exit 1
fi

condition_completed=-1      # completed emerge operations
condition_distance=-1       # distance in hours to the previous image
condition_left=-1           # left entries in backlogs
condition_runtime=-1        # age in days for an image
condition_count=-1          # number of images to be run
condition_bugs=-1           # number of emerges w/o new (==reported) bugs

oldimg=""                   # image to be replaced
setupargs=""                # argument(s) for setup_img.sh

while getopts b:c:d:l:n:o:r:s: opt
do
  case "$opt" in
    b)  condition_bugs="$OPTARG"        ;;
    c)  condition_completed="$OPTARG"   ;;
    d)  condition_distance="$OPTARG"    ;;
    l)  condition_left="$OPTARG"        ;;
    n)  condition_count="$OPTARG"       ;;
    r)  condition_runtime="$OPTARG"     ;;

    o)  oldimg="${OPTARG##*/}"          ;;
    s)  setupargs="$OPTARG"             ;;
    *)  echo " opt not implemented: '$opt'"; exit 1;;
  esac
done

if [[ -n "$oldimg" ]]; then
  if StopOldImage "user decision"; then
    exec nice -n 1 sudo ${0%/*}/setup_img.sh $setupargs
  fi
fi

# do not run in parallel (in automatic mode)
lockfile="/tmp/${0##*/}.lck"
if [[ -s "$lockfile" ]]; then
  if kill -0 $(cat $lockfile) 2>/dev/null; then
    exit 1    # a previous instance is (still) running
  else
    echo " found stale lockfile content:"
    cat $lockfile
  fi
fi
echo $$ > "$lockfile" || exit 1
trap Finish INT QUIT TERM EXIT

while FreeSlotAvailable
do
  setupANewImage
done

while HasAnEmptyBacklog
do
  if StopOldImage "empty backlogs"; then
    setupANewImage
  fi
done

while BrokenAndTooOldToRepair
do
  if StopOldImage "broken:  ~tinderbox/img/$oldimg/var/tmp/tb/@world.last.log"; then
    setupANewImage
  fi
done

while ReplaceAnImage
do
  if StopOldImage "$reason"; then
    setupANewImage
  fi
done

Finish 0
