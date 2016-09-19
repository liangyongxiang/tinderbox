#!/bin/sh
#
# set -x

# this is the tinderbox script - it runs within the chroot image for few weeks
#

# barrier start
# this prevents the start of a broken copy of ourself - see end of file too
#
(

# strip away escape sequences
#
function stresc() {
  # remove colour ESC sequences, ^[[K and carriage return
  # do not use perl -ne 's/\e\[?.*?[\@-~]//g; print' due to : https://bugs.gentoo.org/show_bug.cgi?id=564998#c6
  #
  perl -MTerm::ANSIColor=colorstrip -nle '$_ = colorstrip($_); s/\e\[K//g; s/\r/\n/g; print'
}


# send out an email with $1 as the subject and $2 as the body
#
function Mail() {
  subject=$(echo "$1" | cut -c1-200)
  ( [[ -e $2 ]] && stresc < $2 || date ) | mail -s "$subject    @ $name" $mailto &>> /tmp/mail.log
}


# clean up and exit
#
function Finish()  {
  Mail "FINISHED: $*" $log
  rm -f /tmp/STOP

  exit 0
}


# for a package do evaluate here if it is worth to call emerge
#
function GetNextTask() {
  #   update @system once a day, if no special task is scheduled
  #
  ts=/tmp/timestamp.system
  if [[ ! -f $ts ]]; then
    touch $ts
  else
    let "diff = $(date +%s) - $(date +%s -r $ts)"
    if [[ $diff -gt 86400 ]]; then
      grep -q -E "^(STOP|INFO|%|@)" $pks
      if [[ $? -ne 0 ]]; then
        task="@system"
        SwitchJDK
        return
      fi
    fi
  fi

  # splice last line of the package list $pks into $task
  #
  while :;
  do
    task=$(tail -n 1 $pks)
    sed -i -e '$d' $pks

    if [[ -n "$(echo $task | grep '^INFO')" ]]; then
      Mail "$task"

    elif [[ -n "$(echo $task | grep '^STOP')" ]]; then
      Finish "$task"

    elif  [[ -z "$task" ]]; then
      if [[ -s $pks ]]; then
        continue  # package list itself isn't empty, just this line
      fi

      # we reached the end of the lifetime
      #
      /usr/bin/pfl &>/dev/null
      n=$(qlist --installed | wc -l)
      Finish "$n packages emerged"

    elif [[ "$(echo $task | cut -c1)" = '%' ]]; then
      return  # a complete command line

    elif [[ "$(echo $task | cut -c1)" = '@' ]]; then
      return  # a package set

    else
      # a package
      #
      echo "$task" | grep -q -f /tmp/tb/data/IGNORE_PACKAGES
      if [[ $? -eq 0 ]]; then
        continue
      fi

      # skip if $task is masked or an invalid string
      #
      best_visible=$(portageq best_visible / $task 2>/dev/null)
      if [[ $? -ne 0 || -z "$best_visible" ]]; then
        continue
      fi

      # skip if installed $task is up to date or would be downgraded
      #
      installed=$(portageq best_version / $task)
      if [[ -n "$installed" ]]; then
        qatom --compare $installed $best_visible | grep -q -e ' == ' -e ' > '
        if [[ $? -eq 0 ]]; then
          continue
        fi
      fi

      # well, call emerge on $task
      #
      return
    fi
  done
}


# collect convenient information
#
function CollectIssueFiles() {
  ehist=/var/tmp/portage/emerge-history.txt
  cmd="qlop --nocolor --gauge --human --list --unlist"

  echo "# This file contains the emerge history got with:" > $ehist
  echo "# $cmd" >> $ehist
  echo "#"      >> $ehist
  $cmd          >> $ehist

  # misc build logs
  #
  cflog=$(grep -m 1 -A 2 'Please attach the following file when seeking support:'    $bak | grep "config\.log"     | cut -f2 -d' ')
  apout=$(grep -m 1 -A 2 'Include in your bugreport the contents of'                 $bak | grep "\.out"           | cut -f5 -d' ')
  cmlog=$(grep -m 1 -A 2 'Configuring incomplete, errors occurred'                   $bak | grep "CMake.*\.log"    | cut -f2 -d'"')
  cmerr=$(grep -m 1      'CMake Error: Parse error in cache file'                    $bak | sed  "s/txt./txt/"     | cut -f8 -d' ')
  sandb=$(grep -m 1 -A 1 'ACCESS VIOLATION SUMMARY'                                  $bak | grep "sandbox.*\.log"  | cut -f2 -d'"')
  oracl=$(grep -m 1 -A 1 '# An error report file with more information is saved as:' $bak | grep "\.log"           | cut -f2 -d' ')
  envir=$(grep -m 1      'The ebuild environment file is located at'                 $bak                          | cut -f2 -d"'")
  salso=$(grep -m 1 -A 2 ' See also'                                                 $bak | grep "\.log"           | awk '{ print $1 }' )
#   cnfgr=$(grep -m 1      'Configuring source in'                                     $bak | awk ' { print $5 } ')/configure

  # strip away escape sequences, echo is used to expand those variables containing place holders
  #
  for f in $(echo $ehist $failedlog $cflog $apout $cmlog $cmerr $sandb $oracl $envir $salso) #$cnfgr
  do
    if [[ -f $f ]]; then
      stresc < $f > $issuedir/files/$(basename $f)
    fi
  done

  cp $bak $issuedir

  # compress files bigger than 1 MiByte
  #
  for f in $issuedir/files/* $issuedir/_*
  do
    c=$(wc -c < $f)
    if [[ $c -gt 1000000 ]]; then
      bzip2 $f
    fi
  done
  chmod a+r $issuedir/files/*

  # create an email containing convenient links + info ready for being picked up by copy+paste
  #
  mask="stable"
  grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
  if [[ $? -eq 0 ]]; then
    mask="unstable"
  fi

  cat << EOF >> $issuedir/emerge-info.txt
  -----------------------------------------------------------------

  This is an $mask amd64 chroot image (named $name) at a hardened host acting as a tinderbox.

  -----------------------------------------------------------------
  USE flags ...

  ... in make.conf:
USE="$(source /etc/portage/make.conf; echo -n '  '; echo $USE)"

  ... in /etc/portage/package.use/*:
$(grep -v -e '^#' -e '^$' /etc/portage/package.use/* | cut -f2- -d':' | sed 's/^/  /g')

  entries in /etc/portage/package.unmask/*:
$(grep -v -e '^#' -e '^$' /etc/portage/package.unmask/* | cut -f2- -d':' | sed 's/^/  /g')
  -----------------------------------------------------------------

gcc-config -l:
$(gcc-config -l        2>&1         && echo)
$(eselect java-vm list 2>/dev/null  && echo)
$(eselect python  list 2>&1         && echo)
$(eselect ruby    list 2>/dev/null  && echo)
  -----------------------------------------------------------------

EOF

  # avoid --verbose here, it would blow up the output above the 16 KB limit of b.g.o.
  #
  emerge --info --verbose=n $short >> $issuedir/emerge-info.txt

  # get bug report assignee and cc, GLEP 67 rules
  #
  m=$(equery meta -m $failed | grep '@' | xargs)
  if [[ -z "$m" ]]; then
    m="maintainer-needed@gentoo.org"
  fi

  # if we found more than 1 maintainer, then take the 1st as the assignee
  #
  echo "$m" | grep -q ' '
  if [[ $? -eq 0 ]]; then
    echo "$m" | cut -f1  -d ' ' > $issuedir/assignee
    echo "$m" | cut -f2- -d ' ' | tr ' ' ',' > $issuedir/cc
  else
    echo "$m" > $issuedir/assignee
    touch $issuedir/cc
  fi

  # try to find a descriptive title and the most meaningful lines of the issue
  #
  touch $issuedir/{issue,title}

  if [[ -n "$(grep -m 1 ' * Detected file collision(s):' $bak)" ]]; then
    # we provide package name+version althought this gives more noise in our mail inbox
    #
    s=$(grep -m 1 -A 2 'Press Ctrl-C to Stop' $bak | grep '::' | tr ':' ' ' | cut -f3 -d' ')
    # inform the maintainers of the already installed package too
    #
    cc=$(equery meta -m $s | grep '@' | grep -v "$(cat $issuedir/assignee)" | xargs)
    # sort -u guarantees, that the file $issuedir/cc is completely read in before it will be overwritten
    #
    (cat $issuedir/cc; echo $cc) | tr ',' ' '| xargs -n 1 | sort -u | xargs | tr ' ' ',' > $issuedir/cc

    grep -m 1 -A 20 ' * Detected file collision(s):' $bak | grep -B 15 ' * Package .* NOT' > $issuedir/issue
    echo "file collision with $s" > $issuedir/title

  elif [[ -f $sandb ]]; then
    is_sandbox_issue=1

    p="$(grep -m1 ^A: $sandb)"
    echo "$p" | grep -q "A: /root/"
    if [[ $? -eq 0 ]]; then
      # handle XDG sandbox issues in a special way
      #
      cat <<EOF > $issuedir/issue
This issue is forced at the tinderbox by making:

$(grep '^export XDG_' /tmp/job.sh)

pls see bug #567192 too

EOF
      echo "sandbox issue (XDG_xxx_DIR related)" > $issuedir/title
    else
      # other sandbox issues
      #
      echo "sandbox issue $p" > $issuedir/title
    fi
    head -n 20 $sandb >> $issuedir/issue

  else
    # to catch the real culprit we've loop over all patterns exactly in their order
    # therefore we can't use "grep -f CATCH_ISSUES"
    #
    cat /tmp/tb/data/CATCH_ISSUES |\
    while read c
    do
      grep -m 1 -B 2 -A 3 "$c" $bak > $issuedir/issue
      if [[ -s $issuedir/issue ]]; then
        head -n 3 < $issuedir/issue | tail -n 1 > $issuedir/title
        break
      fi
    done
  fi

  # shrink too long error messages like "/a/b/c.h:23: error 1"
  #
  sed -i -e 's#/[^ ]*\(/[^/:]*:\)#/...\1#g' $issuedir/title

  # kick off hex addresses and such stuff to improve search results in b.g.o.
  #
  sed -i -e 's/0x[0-9a-f]*/<snip>/g' -e 's/: line [0-9]*:/:line <snip>:/g' $issuedir/title

  # guess from the title if there's a bug tracker for this issue
  # the BLOCKER file must follow this syntax:
  #
  #   # comment
  #   <bug id>
  #   <pattern>
  #   ...
  #
  # if <pattern> is defined multiple times the first will win
  #
  block=$(
    grep -v -e '^#' -e '^[1-9].*' /tmp/tb/data/BLOCKER |\
    while read line
    do
      grep -q -E "$line" $issuedir/title
      if [[ $? -eq 0 ]]; then
        echo -n "-b "
        grep -m 1 -B 1 "$line" /tmp/tb/data/BLOCKER | head -n 1
        break
      fi
    done
  )

  # the email contains:
  # - the issue, package version and maintainer
  # - a bgo.sh command line ready for copy+paste
  # - bugzilla search result/s
  #
  cp $issuedir/issue $issuedir/body

  cat << EOF >> $issuedir/body

--
versions: $(eshowkw -a amd64 $short | grep -A 100 '^-' | grep -v '^-' | awk '{ if ($3 == "+") { print $1 } else { print $3$1 } }' | xargs)
assignee: $(cat $issuedir/assignee)
cc:       $(cat $issuedir/cc)
--

EOF

  # search if $issue is already filed or return a list of similar records
  #
  # replace in search string the package version with its name only and strip away quotes
  #
  id=$(bugz -q --columns 400 search --status OPEN,RESOLVED --show-status $short $(cut -f3- -d' ' $issuedir/title | tr "['‘\"]" " ") 2>/dev/null | tail -n 1 | grep '^[[:digit:]]* ' | tee -a $issuedir/body | cut -f1 -d ' ')
  if [[ -n "$id" ]]; then
    cat << EOF >> $issuedir/body
  https://bugs.gentoo.org/show_bug.cgi?id=$id

  ~/tb/bin/bgo.sh -d $name/$issuedir -a $id

EOF
  else
    echo -e "  ~/tb/bin/bgo.sh -d $name/$issuedir $block\n" >> $issuedir/body

    h="https://bugs.gentoo.org/buglist.cgi?query_format=advanced&short_desc_type=allwordssubstr"
    g="stabilize|Bump| keyword| bump"

    echo "  OPEN:     $h&resolution=---&short_desc=$short"      >> $issuedir/body
    bugz --columns 400 -q search --show-status      $short 2>&1 | grep -v -i -E "$g" | tail -n 20 | tac >> $issuedir/body

    echo "" >> $issuedir/body
    echo "  RESOLVED: $h&bug_status=RESOLVED&short_desc=$short" >> $issuedir/body
    bugz --columns 400 -q search --status RESOLVED  $short 2>&1 | grep -v -i -E "$g" | tail -n 20 | tac >> $issuedir/body
  fi

  # attach now collected files
  #
  for f in $issuedir/emerge-info.txt $issuedir/files/* $issuedir/_*
  do
    uuencode $f $(basename $f) >> $issuedir/body
  done

  # prefix the Subject with package name + version
  #
  sed -i -e "s#^#$failed : #" $issuedir/title

  # b.g.o. limits "Summary" to 255 chars
  #
  if [[ $(wc -c < $issuedir/title) -gt 255 ]]; then
    truncate -s 255 $issuedir/title
  fi

  chmod    777  $issuedir/{,files}
  chmod -R a+rw $issuedir/
}


# put all successfully emerged dependencies of $task into the world file
# otherwise we'd need "--deep" (https://bugs.gentoo.org/show_bug.cgi?id=563482)
#
function PutDepsIntoWorld()  {
  line=$(tac /var/log/emerge.log | grep -m 1 -E ':  === |: Started emerge on: ')
  echo "$line" | grep -q ':  === ('
  if [[ $? -eq 0 ]]; then
    echo "$line" | grep -q ':  === (1 of '
    if [[ $? -ne 0 ]]; then
      emerge --depclean --pretend --verbose=n 2>/dev/null | grep "^All selected packages: " | cut -f2- -d':' | xargs emerge --noreplace &>/dev/null
    fi
  fi
}


# collect all useful information together
#
function GotAnIssue()  {
  # prefix our log backup file with an "_" to distinguish it from portage's log files
  #
  bak=/var/log/portage/_emerge_$(date +%Y%m%d-%H%M%S).log
  stresc < $log > $bak

  PutDepsIntoWorld

  # mostly OOM
  #
  fatal=$(grep -f /tmp/tb/data/FATAL_ISSUES $bak)
  if [[ -n "$fatal" ]]; then
    Finish "FATAL: $fatal"
  fi

  # the host repository is synced every 3 hours, that might interfere with a longer emerge operation
  # the final solution is a local repo, but no way as long as we just have 16 GB RAM at all
  #
  grep -q 'AssertionError: ebuild not found for' $bak
  if [[ $? -eq 0 ]]; then
    Mail "notice: race of repository sync and local emerge" $bak  # mail to us to check that we're not in a loop
    return
  fi

  # missing or wrong USE flags, license, fetch restrictions et al
  # we do not mask those package b/c the root cause might be fixed/circumvent during the lifetime of the image
  #
  grep -q -f /tmp/tb/data/IGNORE_ISSUES $bak
  if [[ $? -eq 0 ]]; then
    return
  fi

  grep -q 'Always study the list of packages to be cleaned for any obvious' $bak
  if [[ $? -eq 0 ]]; then
    Mail "notice: depclean failed" $bak
    return
  fi

  # the package specific log file
  #
  failedlog=$(grep -m 1 "The complete build log is located at" $bak | cut -f2 -d"'")
  if [[ -z "$failedlog" ]]; then
    failedlog=$(grep -m 1 -A 1 "', Log file:" $bak | tail -n 1 | cut -f2 -d"'")
    if [[ -z "$failedlog" ]]; then
      failedlog=$(grep -m 1 "^>>>  '" $bak | cut -f2 -d"'")
    fi
  fi

  # $failed contains package name + version + revision
  #
  if [[ -n "$failedlog" ]]; then
    failed=$(basename $failedlog | cut -f1-2 -d':' | tr ':' '/')
  else
    # guess the actually failed package
    #
    # alternatives :
    #[20:43] <_AxS_> toralf:   grep -l "If you need support, post the output of" /var/tmp/portage/*/*/temp/build.log   <-- that should work in all but maybe fetch failures.
    #[20:38] <kensington> something like itfailed() { echo "${PF} - $(date)" >> failed.log }  register_die_hook itfailed in /etc/portage/bashrc
    #
    failed="$(cd /var/tmp/portage; ls -1d */* 2>/dev/null)"
    if [[ -z "$failedlog" ]]; then
      failedlog=$(ls -1t /var/log/portage/$(echo "$failed" | tr '/' ':'):????????-??????.log 2>/dev/null | head -n 1)
    fi
  fi

  # after this point we expect that we catched an issue with a single package
  #
  if [[ -z "$failed" ]]; then
    Mail "warn: \$failed is empty for task: $task" $bak
    return
  fi

  short=$(qatom $failed | cut -f1-2 -d' ' | tr ' ' '/')
  if [[ -z "$short" ]]; then
    Mail "warn: \$short is empty for failed: $failed" $bak
    return
  fi

  # collect build + log files into $issuedir
  #
  issuedir=/tmp/issues/$(date +%Y%m%d-%H%M%S)_$(echo $failed | tr '/' '_')
  mkdir -p $issuedir/files
  is_sandbox_issue=0
  CollectIssueFiles

  # Perl upgrade issue: https://bugs.gentoo.org/show_bug.cgi?id=41124  https://bugs.gentoo.org/show_bug.cgi?id=570460
  #
  grep -q -e 'perl module is required for intltool' -e "Can't locate .* in @INC" $bak
  if [[ $? -eq 0 ]]; then
    (
    cd /;
    tar -cjpf $issuedir/var.db.pkg.tbz2       var/db/pkg
    tar -cjpf $issuedir/var.lib.portage.tbz2  var/lib/portage
    tar -cjpf $issuedir/etc.portage.tbz2      etc/portage
    )
    if [[ "$task" = "@system" ]]; then
      Mail "notice: auto.fixing Perl upgrade issue in $task" $bak
      echo -e "$task\nINFO pls check if the Perl upgrade issue is solved for $task\n%perl-cleaner --force --libperl\n%perl-cleaner --modules" >> $pks
      return
    fi
  fi

  if [[ $is_sandbox_issue -eq 1 ]]; then
    # build this specific package version w/o sandboxing from now on
    #
    echo "=$failed nosandbox" >> /etc/portage/package.env/nosandbox
    echo "$task" >> $pks
  else
    # mask this particular package version
    #
    grep -q "=$failed$" /etc/portage/package.mask/self
    if [[ $? -ne 0 ]]; then
      echo "=$failed" >> /etc/portage/package.mask/self
    fi
  fi

  # don't send an email if an issue is in ALREADY_CATCHED
  # or if the issue has already a bug report
  #
  grep -F -q -f $issuedir/title /tmp/tb/data/ALREADY_CATCHED
  if [[ $? -ne 0 ]]; then
    cat $issuedir/title >> /tmp/tb/data/ALREADY_CATCHED
    if [[ -z "$id" ]]; then
      Mail "${id:-ISSUE} $(cat $issuedir/title)" $issuedir/body
    fi
  fi
}


# switch the java engine
#
function SwitchJDK()  {
  old=$(eselect java-vm show system 2>/dev/null | tail -n 1 | xargs)
  if [[ -n "$old" ]]; then
    new=$(eselect java-vm list 2>/dev/null | grep -E 'oracle-jdk-[[:digit:]]|icedtea[-bin]*-[[:digit:]]' | grep -v 'system-vm' | awk ' { print $2 } ' | sort --random-sort | head -n 1)
    if [[ -n "$new" ]]; then
      if [[ "$new" != "$old" ]]; then
        eselect java-vm set system $new &> $log
        if [[ $? -ne 0 ]]; then
          Mail "$FUNCNAME failed for $old -> $new" $log
        fi
      fi
    fi
  fi
}


# *compiled* kernel modules are needed by some packages
#
function BuildKernel()  {
  (
    cd /usr/src/linux     &&\
    make defconfig        &&\
    make modules_prepare  &&\
    make                  &&\
    make modules_install  &&\
    make install
  ) &> $log
  rc=$?

  if [[ $rc -ne 0 ]]; then
    Finish "ERROR: $FUNCNAME failed (rc=$rc)"
  fi
}


# switch to latest GCC, see: https://wiki.gentoo.org/wiki/Upgrading_GCC
#
function SwitchGCC() {
  latest=$(gcc-config --list-profiles --nocolor | cut -f3 -d' ' | grep 'x86_64-pc-linux-gnu-.*[0-9]$' | tail -n 1)
  gcc-config --list-profiles --nocolor | grep -q "$latest \*$"
  if [[ $? -ne 0 ]]; then
    # schedule kernel rebuild if it was build before
    #
    if [[ -e /usr/src/linux/.config ]]; then
      (cd /usr/src/linux && make clean 2>>$log)
      echo "%BuildKernel" >> $pks
    fi

    verold=$(gcc -v 2>&1 | tail -n 1 | cut -f1-3 -d' ')
    gcc-config --nocolor $latest &> $log
    . /etc/profile
    vernew=$(gcc -v 2>&1 | tail -n 1 | cut -f1-3 -d' ')

    majold=$(echo $verold | cut -f3 -d ' ' | cut -c1)
    majnew=$(echo $vernew | cut -f3 -d ' ' | cut -c1)

    # re-build affected software against new GCC libs is mandatory
    #
    if [[ "$majold" != "$majnew" ]]; then
      if [[ "$majnew" = "5" || "$majnew" = "6" ]]; then
        cmd="revdep-rebuild --ignore --library libstdc++.so.6 -- --exclude gcc"
      else
        Finish "ERROR: $FUNCNAME from $verold to $vernew rebuild not implemented"
      fi

      $cmd &>> $log
      if [[ $? -ne 0 ]]; then
        GotAnIssue
        echo "%$cmd" >> $pks
        Finish "FAILED: $FUNCNAME from $verold to $vernew rebuild failed"
      else
        # clean up old GCC to double-ensure that packages builds against the new version
        #
        echo "%emerge --unmerge =sys-devel/gcc-${verold}*"
      fi
    fi
  fi
}


# eselect the latest *emerged* kernel and schedule a build if necessary
#
function SelectNewKernel() {
  last=$(ls -1dt /usr/src/linux-* | head -n 1 | cut -f4 -d'/')
  link=$(eselect kernel show | tail -n 1 | sed -e 's/ //g' | cut -f4 -d'/')

  if [[ "$last" != "$link" ]]; then
    eselect kernel set $last &>> $log
    if [[ ! -f /usr/src/linux/.config ]]; then
      echo "%BuildKernel" >> $pks
    fi
  fi
}


# we do just *schedule* emerge operation here
# by appending them in their opposite order to the package list
#
function PostEmerge() {
  # do not auto-update these config files
  #
  rm -f /etc/ssmtp/._cfg????_ssmtp.conf
  rm -f /etc/portage/._cfg????_make.conf

  etc-update --automode -5 &>/dev/null
  env-update &>/dev/null
  . /etc/profile

  grep -q "IMPORTANT: config file '/etc/locale.gen' needs updating." $log
  if [[ $? -eq 0 ]]; then
    locale-gen &>/dev/null
  fi

  grep -q ">>> Installing .* sys-kernel/.*-sources" $log
  if [[ $? -eq 0 ]]; then
    SelectNewKernel
  fi

  grep -q "Use emerge @preserved-rebuild to rebuild packages using these libraries" $log
  if [[ $? -eq 0 ]]; then
    n=$(tac /var/log/emerge.log | grep -F -m 20 '*** emerge' | grep -c "emerge .* @preserved-rebuild")
    if [[ $n -gt 4 ]]; then
      # even if the root cause of the @preserved-rebuild issue was solved the test above would still be true
      # therefore we need a marker which tells us to ignore the test
      # this marker is the truncastion of the file of the @preserved-rebuild history
      #
      f=/tmp/timestamp.preserved-rebuild
      if [[ -s $f ]]; then
        chmod a+w $f
        Finish "${n}x @preserved-rebuild, run 'truncate -s 0 $name/$f' before next start"
      fi
    fi
    echo "@preserved-rebuild" >> $pks
  fi

  grep -q -e "Please, run 'haskell-updater'" -e "ghc-pkg check: 'checking for other broken packages:'" $log
  if [[ $? -eq 0 ]]; then
    echo "%haskell-updater" >> $pks
  fi

  grep -q ">>> Installing .* sys-devel/gcc-[1-9]" $log
  if [[ $? -eq 0 ]]; then
    echo "%SwitchGCC" >> $pks
  fi

  grep -q 'Please run "revdep-pax" after installation.' $log
  if [[ $? -eq 0 ]]; then
    echo "%revdep-pax" >> $pks
  fi

  grep -q ">>> Installing .* dev-lang/perl-[1-9]" $log
  if [[ $? -eq 0 ]]; then
    echo "%perl-cleaner --all" >> $pks
  fi

  # auto-unmerge packages, eg:
  #
  # !!! The following installed packages are masked:
  # - dev-ruby/dep_selector-0.1.1::gentoo (masked by: package.mask)
  #
  del=$(grep '^\- .*/.* (masked by: package.mask)$' $log | cut -f2 -d ' ' | cut -f1 -d ':' | sed 's/^/=/g')
  if [[ -n "$del" ]]; then
    first=1
    for p in $del
    do
      equery --quiet depends --indirect $p 1>/dev/null
      if [[ $? -eq 1 ]]; then
        if [[ $first -eq 1 ]]; then
          first=0
          echo "%PutDepsIntoWorld" >> $pks
        fi
        echo "%emerge --unmerge $p" >> $pks
      fi
    done
  fi
}


# test hook, eg. to catch install artefacts
#
function check() {
  exe=/tmp/tb/bin/PRE-CHECK.sh

  if [[ -x $exe ]]; then
    out=/tmp/check.log

    $exe &> $out
    rc=$?

    # -1 == 255:-2 == 254, ...
    #
    if [[ $rc -gt 127 ]]; then
      Finish "$exe returned $rc"

    elif [[ $rc -gt 0 ]]; then
      echo                                  >> $out
      echo "seen at tinderbox image $name"  >> $out
      echo                                  >> $out
      tail -n 30 $log                       >> $out
      echo                                  >> $out
      emerge --info $task                   >> $out
      echo                                  >> $out
      Mail "$exe : rc=$rc, task=$task" $out
    fi

    rm $out
  fi
}


# $task might be @set, a command line like "%emerge -C ..." or a single package
#
function EmergeTask() {
  if [[ "$task" = "@preserved-rebuild" ]]; then
    emerge --backtrack=30 $task &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue
    fi

    date >> /tmp/timestamp.preserved-rebuild  # timestamp, successful or not
    PostEmerge

  elif [[ "$task" = "@system" ]]; then
    emerge --deep --update --changed-use --with-bdeps=y $task &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue

      # quirk for the very first @system after initial setup
      #
      if [[ -f /etc/portage/package.mask/upgrade_blocker ]]; then
        rm /etc/portage/package.mask/upgrade_blocker
        echo "$task" >> $pks

      elif [[ -n "$(grep 'For more information about Blocked Packages, please refer to the following' $log)" ]]; then
        Mail "info: $task failed" $log

      else
        Finish "notice: $task failed"
      fi

    else
      touch /tmp/timestamp.system
    fi

    PostEmerge
    /usr/bin/pfl &>/dev/null

  else
    # run a command line (prefixed with "%") or just emerge a package
    #
    if [[ "$(echo $task | cut -c1)" = '%' ]]; then
      cmd=$(echo "$task" | cut -c2-)
    else
      cmd="emerge --update $task"
    fi

    $cmd &> $log
    if [[ $? -ne 0 ]]; then
      GotAnIssue
    fi
    PostEmerge
  fi
}


#############################################################################
#
#       main
#
mailto="tinderbox@zwiebeltoralf.de"
log=/tmp/task.log                   # holds always output of "emerge ... "
pks=/tmp/packages                   # the pre-filled package list file

export GCC_COLORS=""                # suppress colour output of gcc-4.9 and above

# eg.: amd64-gnome-unstable_20150913-104240
#
name=$(grep "^PORTAGE_ELOG_MAILFROM=" /etc/portage/make.conf | cut -f2 -d '"' | cut -f1 -d ' ')

# got from [20:25] <mgorny> toralf: also, my make.conf: http://dpaste.com/3CM0WK8 ;-)
# https://bugs.gentoo.org/show_bug.cgi?id=567192
#
export XDG_DESKTOP_DIR="/root/Desktop"
export XDG_DOCUMENTS_DIR="/root/Documents"
export XDG_DOWNLOAD_DIR="/root/Downloads"
export XDG_MUSIC_DIR="/root/Music"
export XDG_PICTURES_DIR="/root/Pictures"
export XDG_PUBLICSHARE_DIR="/root/Public"
export XDG_TEMPLATES_DIR="/root/Templates"
export XDG_VIDEOS_DIR="/root/Videos"

export XDG_RUNTIME_DIR="/root/run"
export XDG_CONFIG_HOME="/root/config"
export XDG_CACHE_HOME="/root/cache"
export XDG_DATA_HOME="/root/share"

while :;
do
  # restart ourself if we do differ from us
  #
  diff -q /tmp/tb/bin/job.sh /tmp/job.sh 1>/dev/null
  if [[ $? -ne 0 ]]; then
    exit 125
  fi

  check
  rm -rf /var/tmp/portage/*

  date > $log
  if [[ -f /tmp/STOP ]]; then
    Finish "catched stop signal"
  fi

  GetNextTask
  EmergeTask
done

Finish "Bummer! We should never reach this line !"

# barrier end (see start of this file too)
#
)
