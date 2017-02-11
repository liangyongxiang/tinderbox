#!/bin/sh
#
# set -x

# quick & dirty stats
#

# all active|running images
#
function list_images() {
  (
    ls -1d ~/run/* | xargs -n 1 readlink | sed "s,^..,/home/tinderbox,g"
    df -h | grep '/home/tinderbox/img./' | cut -f4-5 -d'/' | sed "s,^,/home/tinderbox/,g"
  ) | sort -u
}


# gives sth. like:
#
#  inst fail  day  todo ~/run lock stop
#  5254   97  7.8 14862     Y    Y    n 13.0-no-multilib-unstable_20170203-153432
#   587    8  0.9 19021     Y    Y    n 13.0-systemd-libressl-unstable-abi32+64_20170210-142202
#  3689   40  4.6 15088     Y    Y    n desktop-stable_20170206-184215
#
function Overall() {
  echo " inst fail  day  todo ~/run lock stop"
  for i in $images
  do
    log=$i/var/log/emerge.log
    if [[ -f $log ]]; then
      inst=$(grep -c '::: completed emerge' $log)
      day=$(echo "scale=1; ($(tail -n1 $log | cut -c1-10) - $(head -n1 $log | cut -c1-10)) / 86400" | bc)
    else
      inst=0
      day=0
    fi
    # we do count fail package, not fail attempts of the same package version
    #
    fail=$(ls -1 $i/tmp/issues 2>/dev/null | xargs -n 1 basename | cut -f2- -d'_' | sort -u | wc -w)
    todo=$(wc -l < $i/tmp/packages 2>/dev/null)

    [[ -e ~/run/$(basename $i) ]] && run="Y"  || run="n"
    [[ -f $i/tmp/LOCK ]]          && lock="Y" || lock="n"
    [[ -f $i/tmp/STOP ]]          && stop="Y" || stop="n"

    printf "%5i %4i %4.1f %5i %5s %4s %4s %s\n" $inst $fail $day $todo $run $lock $stop $(basename $i)
  done
}


# gives sth. like:
#
# 13.0-no-multilib-unstable_20170203-153432          0h  0m 37s >>> (1 of 1) dev-php/pecl-timezonedb-2016.10
# desktop-stable_20170206-184215                     1h  0m 46s >>> (23 of 25) dev-games/openscenegraph-3.4.0
# desktop-unstable_20170127-120123                   0h  0m 58s
#
function LastEmergeOperation()  {
  for i in $images
  do
    log=$i/var/log/emerge.log
    printf "%s\r\t\t\t\t\t" $(basename $i)
    if [[ -f $log ]]; then
      tac $log |\
      grep -m 1 -E -e '(>>>|\*\*\*) emerge' -e '::: completed emerge' |\
      sed -e 's/ \-\-.* / /g' -e 's, to /,,g' -e 's/ emerge / /g' -e 's/ completed / /g' -e 's/ \*\*\*.*//g' |\
      perl -wane '
        chop ($F[0]);

        my $diff = time() - $F[0];
        my $hh = $diff / 60 / 60;
        my $mm = $diff / 60 % 60;
        my $ss = $diff % 60 % 60;

        printf ("  %2ih %2im %02is %s\n", $hh, $mm, $ss, join (" ", @F[1..$#F]));
      '
    else
      echo "        "
    fi
  done
}


# gives sth. like:
#
# gnome-unstable_20170201-093005                    655   56
# hardened-no-multilib-libressl-unstable_20170131- 1062  798
# hardened-unstable_20170129-183636                 344  870 1045  503
#
function PackagesPerDay() {
  for i in $images
  do
    log=$i/var/log/emerge.log
    printf "%s\r\t\t\t\t\t" $(basename $i)
    if [[ -f $log ]]; then
      echo -n "  "

      # qlop gives sth like: Fri Aug 19 13:43:15 2016 >>> app-portage/cpuid2cpuflags-1
      #
      grep '::: completed emerge' $log |\
      cut -f1 -d ':' |\
      perl -wane '
        BEGIN { @p = (); $first = 0}
        {
          $cur = $F[0];
          $first = $cur if ($first == 0);
          my $i = int (($cur-$first)/86400);
          $p[$i]++;
        }

        END {
          foreach my $i (0..$#p) {
            printf ("%5i", $p[$i]);
          }
        }
      '
      echo " "
    else
      echo "        "
    fi
  done
}


# gives sth. like:
#
# 13.0-no-multilib-unstable_20170203-153432          0h  0m 52s  games-puzzle/tanglet
# 13.0-systemd-libressl-unstable_20170130-102323     0h  0m 39s  @preserved-rebuild
# desktop-unstable_20170127-120123                   0h  2m 00s  app-text/bibletime
#
function CurrentTask()  {
  for i in $images
  do
    tsk=$i/tmp/task
    printf "%s\r\t\t\t\t\t\t" $(basename $i)
    if [[ -f $tsk ]]; then
      delta=$(echo "$(date +%s) - $(date +%s -r $tsk)" | bc)
      seconds=$(echo "$delta % 60" | bc)
      minutes=$(echo "$delta / 60 % 60" | bc)
      hours=$(echo "$delta / 60 / 60" | bc)
      printf "  %2ih %2im %02is  " $hours $minutes $seconds
      cat $i/tmp/task
    else
      echo "        "
    fi
  done
}


#######################################################################
#
images=$(list_images)

echo
echo "$(echo $images | wc -w) images ($(ls ~/img? | wc -w) at all) :"

while getopts hlopt\? opt
do
  echo

  # ignore stderr but keep its setting
  #
#   exec 3>&2
#   exec 2> /dev/null

  case $opt in
    l)  LastEmergeOperation
        ;;
    o)  Overall
        ;;
    p)  PackagesPerDay
        ;;
    t)  CurrentTask
        ;;
    *)  echo "call: $(basename $0) [-l] [-o] [-p] [-t]"
        echo
        exit 0
        ;;
  esac

#   exec 2>&3
done

echo
