#!/bin/bash
# set -x

# print tinderbox statistics


function PrintImageName()  {
  # ${n} is the minimum length to distinguish image names
  n=30
  printf "%-${n}s" $(cut -c-$n <<< ${1##*/})
}


function check_history()  {
  file=$1
  lc=$2

  # eg. for @system:
  # X = @x failed at all to start
  # x = @x failed due to a package issue
  # . = never run before
  #   = no issues
  if [[ -s $file ]]; then
    if tail -n 1 $file | grep -q " NOT ok"; then
      uc=$(tr '[:lower:]' '[:upper:]' <<< $lc)
      flag="${uc}${flag}"
      return
    fi

    if tail -n 1 $file | grep -q " ok"; then
      flag=" $flag"
      return
    fi

    flag="${lc}${flag}"
    return
  fi

  flag=".$flag"
  return
}


# $ whatsup.sh -o
# compl fail bgo days backlog .upd .1st status  7#7 running
#  4402   36   1  4.8   16529    7    0   Wr    run/17.1-20210306-163653
#  4042   26   0  5.1   17774   12    2    r    run/17.1_desktop_gnome-20210306-091529
function Overall() {
  running=$(ls /run/tinderbox/ 2>/dev/null | grep -c '\.lock$' || true)
  all=$(wc -w <<< $images)
  echo "compl fail bgo days backlog .upd .1st status  $running#$all running"

  for i in $images
  do
    days=0
    f=$i/var/tmp/tb/setup.sh
    if [[ -f $f ]]; then
      let "age = $(date +%s) - $(stat -c%Y $f)" || true
      days=$(echo "scale=1; $age / 86400.0" | bc)
    fi

    bgo=$(set +f; ls $i/var/tmp/tb/issues/*/.reported 2>/dev/null | wc -l)

    compl=0
    f=$i/var/log/emerge.log
    if [[ -f $f ]]; then
      compl=$(grep -c ' ::: completed emerge' $f) || true
    fi

    # count emerge failures based on distinct package name+version+release
    # example of an issue directory name: 20200313-044024-net-analyzer_iptraf-ng-1.1.4-r3
    fail=0
    if [[ -d $i/var/tmp/tb/issues ]]; then
      fail=$(ls -1 $i/var/tmp/tb/issues | while read -r i; do echo ${i##/*}; done | cut -f3- -d'-' -s | sort -u | wc -w)
    fi

    bl=$( wc -l 2>/dev/null < $i/var/tmp/tb/backlog    )
    bl1=$(wc -l 2>/dev/null < $i/var/tmp/tb/backlog.1st)
    blu=$(wc -l 2>/dev/null < $i/var/tmp/tb/backlog.upd)

    flag=""
    if __is_running $i ; then
      flag+="r"
    else
      flag+=" "
    fi

    # F=STOP file, f=STOP in backlog
    if [[ -f $i/var/tmp/tb/STOP ]]; then
      flag+="S"
    else
      if grep -q "^STOP" $i/var/tmp/tb/backlog.1st; then
        flag+="s"
      else
        flag+=" "
      fi
    fi

    [[ -f $i/var/tmp/tb/KEEP ]] && flag+="K" || flag+=" "

    # show result of last run of @system, @world and @preserved-rebuild respectively
    # upper case: an error occurred, lower case: a warning occurred
    # a "." means was not run yet and a space, that it was fully ok
    check_history $i/var/tmp/tb/@world.history              w
    check_history $i/var/tmp/tb/@system.history             s
    check_history $i/var/tmp/tb/@preserved-rebuild.history  p

    # images during setup are not already symlinked to ~/run, print so that the position of / is fixed
    b=${i##*/}
    if [[ -e ~/run/$b ]]; then
      d="run"
    else
      d=${i%/*}
      d=${d##*/}
    fi

    printf "%5i %4i %3i %4.1f %7i %4i %4i %6s %4s/%s\n" $compl $fail $bgo $days $bl $blu $bl1 "$flag" "$d" "$b" 2>/dev/null
  done
}


# $ whatsup.sh -t
# 17.1_desktop-20210102  0:19 m  dev-ros/message_to_tf
# 17.1_desktop_plasma_s  0:36 m  dev-perl/Module-Install
function Tasks()  {
  ts=$(date +%s)
  for i in $images
  do
    PrintImageName $i
    if ! __is_running $i ; then
      echo
      continue
    fi

    tsk=$i/var/tmp/tb/task
    if [[ ! -s $tsk ]]; then
      echo
      continue
    fi
    task=$(cat $tsk)

    let "delta = $ts - $(stat -c%Y $tsk)" || true

    if [[ $delta -lt 3600 ]]; then
      let "minutes = $delta / 60 % 60"  || true
      let "seconds = $delta % 60 % 60"  || true
      printf "%3i:%02i m " $minutes $seconds
    else
      let "hours = $delta / 60 / 60"    || true
      let "minutes = $delta / 60 % 60"  || true
      printf "%3i:%02i h " $hours $minutes
    fi

    if [[ ! $task =~ "@" && ! $task =~ "%" && ! $task =~ "#" ]]; then
      echo -n " "
    fi
    echo $task
  done
}


# $ whatsup.sh -l
# 17.1_desktop-20210102
# 17.1_desktop_plasma_s  0:02 m  >>> AUTOCLEAN: media-sound/toolame:0
# 17.1_systemd-20210123  0:44 m  >>> (1 of 2) sci-libs/fcl-0.5.0
function LastEmergeOperation()  {
  for i in $images
  do
    PrintImageName $i
    if ! __is_running $i ; then
      echo
      continue
    fi

    # catch the last *started* emerge operation
    tac $i/var/log/emerge.log 2>/dev/null |\
    grep -m 1 -E -e ' >>>| \*\*\* emerge' -e ' \*\*\* terminating.' -e ' ::: completed emerge' |\
    sed -e 's/ \-\-.* / /g' -e 's, to /,,g' -e 's/ emerge / /g' -e 's/ completed / /g' -e 's/ \*\*\* .*/ /g' |\
    perl -wane '
      next if (scalar @F < 2);

      chop ($F[0]);
      my $delta = time() - $F[0];

      if ($delta < 3600) {
        $minutes = $delta / 60 % 60;
        $seconds = $delta % 60 % 60;
        printf ("%3i:%02i m  ", $minutes, $seconds);
      } else  {
        $hours = $delta / 60 / 60;
        $minutes = $delta / 60 % 60;
        # note long runtimes
        printf ("%3i:%02i h%s ", $hours, $minutes, $delta < 9000 ? " " : "!");
      }
      print join (" ", @F[1..$#F]);
    '
    echo
  done
}


# $ whatsup.sh -p
# 17.1_desktop-20210102  372  832  885  536  528  773  731  715 648 684 500 476 418 610  453 395 353 460 408
# 17.1_desktop_plasma_s  300  640   18  522  803  726  939  794 126
function PackagesPerImagePerRunDay() {
  for i in $images
  do
    PrintImageName $i

    perl -F: -wane '
      # @p helds the amount of emerge operations of (runtime, not calendar) days $i
      BEGIN {
        @packages   = ();  # per days
        $start_time = 0;   # of emerge.log
      }

      my $epoch_time = $F[0];
      $start_time = $epoch_time unless ($start_time);
      next unless (m/::: completed emerge/);

      my $rundays = int(($epoch_time - $start_time) / 86400); # runtime days, starts with "0" (zero)
      $packages[$rundays]++;  # increment # of packages of this rundays

      END {
        $packages[$rundays] += 0;
        foreach my $rundays (0..$#packages) {
          # separate runweeks by an extra space
          printf "." if ($rundays && $rundays % 7 == 0);
          (exists $packages[$rundays]) ? printf "%5i", $packages[$rundays] : printf "    -";
        }
        print "\n";
      }
    ' $i/var/log/emerge.log
  done
}


# whatsup.sh -c
# 22x dev-perl/Module-Build-0.422.400
# 22x dev-perl/Pod-Parser-1.630.0-r1
# 22x virtual/perl-File-Temp-0.230.900
# 1x5169  2x2657  3x2060  4x785  5x463  6x199  7x78  8x79  9x25  10x7  11x5  13x11  14x7  15x1
# total = 25096  unique = 11546
function CountEmergesPerPackages()  {
  perl -wane '
    BEGIN {
      my %pet = ();     # package => emerge times
    }

    $pet{$F[7]}++ if (m/ ::: completed emerge /);

    END {
      my %h = ();       # emerge times => occurrence
      for my $key (sort keys %pet)  {
        my $value = $pet{$key};
        $h{$value}++;
      }

      my $total = 0;    # total amount of emerge operations
      my $unique = 0;   # packages
      for my $key (sort { $a <=> $b } keys %h)  {
        my $value = $h{$key};
        $unique += $value;
        $total += $key * $value;
        print $key, "x", $value, " ";
      }

      print "\n\ntotal: $total   ($unique unique)\n";
    }
  ' ~tinderbox/img/*/var/log/emerge.log
}


# whatsup.sh -e
# 2021.04.10      3551
# 2021.04.11      16540
# 2021.04.12      14296
# 2021.04.13      12605
# 2021.04.14      10796
# 2021.04.15      7372
# 2021.04.16      9557
# 2021.04.17      5542
function emergeThruput()  {
  perl -F: -wane '
    BEGIN {
      my %Day = ();
    }
    {
      next unless (m/::: completed emerge/);

      my $epoch_time = $F[0];
      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($epoch_time);
      $year += 1900;
      $mon = "0" . $mon if ($mon < 10);
      $mday = "0" . $mday if ($mday < 10);

      my $key = $year . "-" . $mon . "-" . $mday;
      $Day{$key}->{$hour}++;
      $Day{$key}->{"day"}++;
    }

    END {
      print "yyyy-mm-dd   sum   0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16  17  18  19  20  21  22  23\n\n";
      for my $key (sort { $a cmp $b } keys %Day)  {
        printf("%s %5i", $key, $Day{$key}->{"day"});
        foreach my $hour(0..23) {

          printf("%4i", $Day{$key}->{$hour} ? $Day{$key}->{$hour} : 0);
        }
        print "\n";
      }
    }
  ' ~tinderbox/img/*/var/log/emerge.log
}


#############################################################################
#
# main
#
set -eu
export LANG=C.utf8
unset LC_TIME

source $(dirname $0)/lib.sh

images=$(__list_images)

while getopts cehlopt\? opt
do
  case $opt in
    c)  CountEmergesPerPackages   ;;
    e)  emergeThruput             ;;
    l)  LastEmergeOperation       ;;
    o)  Overall                   ;;
    p)  PackagesPerImagePerRunDay ;;
    t)  Tasks                     ;;
  esac
  echo
done
