# #!/bin/sh
#
# set -x


# This is the tinderbox script itself.
# The main function is WorkOnTask().
# The remaining code just parses the output.
# That's all.


# strip away escape sequences
# hint: colorstrip() doesn't modify its argument, instead it returns the result
#
function stresc() {
  perl -MTerm::ANSIColor=colorstrip -nle '
    $_ = colorstrip($_);
    s,\r,\n,g;
    s,\x00,,g;
    s,\x08,,g;
    s,\b,,g;
    s,\x1b\x28\x42,,g;
    s,\x1b\x5b\x4b,,g;
    s,,,g;
    print;
  '
}


# send an email, $1 (mandatory) is the subject, $2 (optional) contains the body
#
function Mail() {
  subject=$(echo "$1" | stresc | cut -c1-200 | tr '\n' ' ')
  (
    if [[ -f $2 ]]; then
      stresc < $2
    else
      echo "${2:-<no body>}"
    fi
  ) | timeout 120 mail -s "$subject    @ $name" $mailto -a '' &>> /tmp/mail.log
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$(date) mail failed with rc=$rc issuedir=$issuedir" | tee -a /tmp/mail.log
  fi
}


# clean up and exit
# $1: return code, $2: email Subject
#
function Finish()  {
  local rc=$1

  # although stresc() is called in Mail() run it here too b/c $2 might contain quotes
  #
  subject=$(echo "$2" | stresc | cut -c1-200 | tr '\n' ' ')

  /usr/bin/pfl &> /dev/null

  if [[ $rc -eq 0 ]]; then
    Mail "Finish ok: $subject"
  else
    Mail "Finish NOT ok, rc=$rc: $subject" $log
  fi

  if [[ $rc -eq 0 ]]; then
    rm -f $tsk
  fi

  rm -f /tmp/STOP

  exit $rc
}


# move next item of the appropriate backlog into $task
#
function setNextTask() {
  while :
  do
    if [[ -f /tmp/STOP ]]; then
      Finish 0 "catched STOP file"
    fi

    # re-try an unfinished task (eg.: due to a reboot)
    #
    if [[ -s $tsk ]]; then
      task=$(cat $tsk)
      return
    fi

    # this backlog is only filled by us -or- was pre-filled from the cloned image backlog
    #
    if [[ -s /tmp/backlog.1st ]]; then
      bl=/tmp/backlog.1st

    # mix /tmp/backlog and /tmp/backlog.upd by 50% each but only if no special action is scheduled
    #
    elif [[ -s /tmp/backlog.upd && $(($RANDOM % 2)) -eq 0 && -z "$(grep -E '^(INFO|STOP|@|%)' /tmp/backlog)" ]]; then
      bl=/tmp/backlog.upd

    # filled up during image setup -or- regularly by retest.sh
    #
    elif [[ -s /tmp/backlog ]]; then
      bl=/tmp/backlog

    # last attempt before finishing
    #
    elif [[ -s /tmp/backlog.upd ]]; then
      bl=/tmp/backlog.upd

    # this is the end, my friend, the end ...
    #
    else
      n=$(qlist --installed | wc -l)
      Finish 0 "empty backlog, $n packages emerged"
    fi

    # splice last line from the appropriate backlog file
    #
    task=$(tail -n 1 $bl)
    sed -i -e '$d' $bl

    if [[ -z "$task" ]]; then
      continue  # empty line

    elif [[ $task =~ ^INFO ]]; then
      Mail "$task"

    elif [[ $task =~ ^STOP ]]; then
      Finish 0 "got STOP task"

    elif [[ $task =~ ^# ]]; then
      continue  # comment

    elif [[ $task =~ ^= || $task =~ ^@ || $task =~ ^% ]]; then
      return  # work on a pinned version | package set | command

    else
      # a regular atom
      #
      echo "$task" | grep -q -f /tmp/tb/data/IGNORE_PACKAGES
      if [[ $? -eq 0 ]]; then
        continue
      fi

      # skip if $task is a masked, keyworded or invalid package
      #
      best_visible=$(portageq best_visible / $task 2>/tmp/portageq.err)

      if [[ $? -ne 0 ]]; then
        if [[ "$(grep -ch 'Traceback' /tmp/portageq.err)" -ne "0" ]]; then
          Finish 1 "FATAL: portageq broken" /tmp/portageq.err
        fi
        continue
      fi

      if [[ -z "$best_visible" ]]; then
        continue
      fi

      # skip if $task is already installed and would be downgraded
      #
      installed=$(portageq best_version / $task)
      if [[ -n "$installed" ]]; then
        qatom --compare $installed $best_visible | grep -q -e ' == ' -e ' > '
        if [[ $? -eq 0 ]]; then
          continue
        fi
      fi

      # $task seems to be valid, work on it
      #
      return
    fi
  done
}


# helper of GotAnIssue()
# gather together what's needed for the email and b.g.o.
#
function CollectIssueFiles() {
  mkdir -p $issuedir/files

  ehist=/var/tmp/portage/emerge-history.txt
  local cmd="qlop --nocolor --gauge --human --list --unlist"

  cat << EOF > $ehist
# This file contains the emerge history got with:
# $cmd
#
EOF
  $cmd >> $ehist

  # collect few more build files, strip away escape sequences
  # and compress files bigger than 1 MiByte
  #
  apout=$(grep -m 1 -A 2 'Include in your bugreport the contents of'                 $bak | grep "\.out"          | cut -f5 -d' ' -s)
  cmlog=$(grep -m 1 -A 2 'Configuring incomplete, errors occurred'                   $bak | grep "CMake.*\.log"   | cut -f2 -d'"' -s)
  cmerr=$(grep -m 1      'CMake Error: Parse error in cache file'                    $bak | sed  "s/txt./txt/"    | cut -f8 -d' ' -s)
  oracl=$(grep -m 1 -A 1 '# An error report file with more information is saved as:' $bak | grep "\.log"          | cut -f2 -d' ' -s)
  envir=$(grep -m 1      'The ebuild environment file is located at'                 $bak                         | cut -f2 -d"'" -s)
  salso=$(grep -m 1 -A 2 ' See also'                                                 $bak | grep "\.log"          | awk '{ print $1 }' )
  sandb=$(grep -m 1 -A 1 'ACCESS VIOLATION SUMMARY' $bak                                  | grep "sandbox.*\.log" | cut -f2 -d'"' -s)
  roslg=$(grep -m 1 -A 1 'Tests failed. When you file a bug, please attach the following file: ' $bak | grep "/LastTest\.log" | awk ' { print $2 } ')

  # quirk for failing dev-ros/* tests
  #
  grep -q 'ERROR: Unable to contact my own server at' $roslg && echo "TEST ISSUE " > $issuedir/bgo_result

  for f in $ehist $failedlog $sandb $apout $cmlog $cmerr $oracl $envir $salso $roslg
  do
    if [[ -f $f ]]; then
      stresc < $f > $issuedir/files/$(basename $f)
    fi
  done

  # b.g.o. has a limit of 1 MB
  #
  for f in $issuedir/files/* $issuedir/_*
  do
    if [[ $(wc -c < $f) -gt 1000000 ]]; then
      bzip2 $f
    fi
  done

  if [[ -d "$workdir" ]]; then
    # catch all log file(s)
    #
    f=/tmp/files
    (
      cd "$workdir/.." &&\
      find ./ -name "*.log" -o -name "testlog.*" > $f &&\
      [[ -s $f ]] &&\
      tar -cjpf $issuedir/files/logs.tbz2 --files-from $f --warning='no-file-ignored'
    )
    rm -f $f

    # provide the whole temp dir if possible
    #
    (
      cd "$workdir"/../.. &&\
      [[ -d ./temp ]]     &&\
      tar -cjpf $issuedir/files/temp.tbz2 --dereference --warning='no-file-removed' --warning='no-file-ignored' ./temp
    )

    # ICE of GCC ?
    #
    if [[ -f $workdir/gcc-build-logs.tar.bz2 ]]; then
      cp $workdir/gcc-build-logs.tar.bz2 $issuedir/files
    fi
  fi

  (cd / && tar -cjpf $issuedir/files/etc.portage.tbz2 --dereference etc/portage)

  chmod a+r $issuedir/files/*
}


# get assignee and cc for the b.g.o. entry
#
function GetAssigneeAndCc() {
  m=$(equery meta -m $short | grep '@' | xargs)

  if [[ -n "$m" ]]; then
    a=$(echo "$m" | cut -f1  -d' ')
    c=$(echo "$m" | cut -f2- -d' ' -s)

    echo "$a" > $issuedir/assignee
    if [[ -n "$c" ]]; then
      echo "$c" > $issuedir/cc
    fi
  else
    echo "maintainer-needed@gentoo.org" > $issuedir/assignee
  fi
}


# add this eg. to #comment0 of an b.g.o. record
#
function AddWhoamiToIssue() {
  cat << EOF >> $issuedir/issue

  -------------------------------------------------------------------

  This is an $keyword amd64 chroot image at a tinderbox (==build bot)
  name: $name

  -------------------------------------------------------------------

EOF
}


# attach given files to the email body
# should be the last part of the email body
#
function AttachFilesToBody()  {
  for f in $*
  do
    s=$( ls -l $f 2>/dev/null | awk ' { print $5 } ' )
    if [[ $s -gt 0 && $s -lt 1048576 ]]; then
      echo >> $issuedir/body
      uuencode $f $(basename $f) >> $issuedir/body
      echo >> $issuedir/body
    fi
  done
}


# this info helps to decide whether to file a bug eg. for a stable package
# despite the fact that the issue was already fixed in an unstable version
#
function AddMetainfoToBody() {
  cat << EOF >> $issuedir/body

--
versions: $(eshowkw -a amd64 $short | grep -A 100 '^-' | grep -v '^-' | awk '{ if ($3 == "+") { print $1 } else if ($3 == "o") { print "**"$1 } else { print $3$1 } }' | xargs)
assignee: $(cat $issuedir/assignee)
cc:       $(cat $issuedir/cc 2>/dev/null)
--

EOF
}


# strip away the version (get $PN from $P)
#
function pn2p() {
  local s=$(qatom "$1" 2>/dev/null)
  if [[ $? -eq 0 ]]; then
    echo $s | cut -f1-2 -d' ' | tr ' ' '/'
  else
    echo ""
  fi
}


# 777: permit every user to edit the files
#
function CreateIssueDir() {
  issuedir=/tmp/issues/$(date +%Y%m%d-%H%M%S)_$(echo $failed | tr '/' '_')
  mkdir -p $issuedir
  chmod 777 $issuedir
}


# helper of ClassifyIssue()
#
function foundCollisionIssue() {
  # provide package name+version althought this gives more noise in our inbox
  #
  s=$(grep -m 1 -A 2 'Press Ctrl-C to Stop' $bak | grep '::' | tr ':' ' ' | cut -f3 -d' ' -s)
  # inform the maintainers of the sibbling package too
  # strip away version + release b/c the repository might be updated in the meanwhile
  #
  cc=$(equery meta -m $(pn2p "$s") | grep '@' | grep -v "$(cat $issuedir/assignee)" | xargs)
  # sort -u guarantees, that the file $issuedir/cc is completely read in before it will be overwritten
  #
  if [[ -n "$cc" ]]; then
    (cat $issuedir/cc 2>/dev/null; echo $cc) | xargs -n 1 | sort -u | xargs > $issuedir/cc
  fi

  grep -m 1 -A 20 ' * Detected file collision(s):' $bak | grep -B 15 ' * Package .* NOT' >> $issuedir/issue
  echo "file collision with $s" > $issuedir/title
}


# helper of ClassifyIssue()
#
function foundSandboxIssue() {
  echo "=$failed nosandbox"     >> /etc/portage/package.env/nosandbox
  echo "=$failed nousersandbox" >> /etc/portage/package.env/nousersandbox
  try_again=1

  p="$(grep -m1 ^A: $sandb)"
  echo "$p" | grep -q "A: /root/"
  if [[ $? -eq 0 ]]; then
    cat << EOF >> $issuedir/issue
This issue is forced at the tinderbox (pls see bug #567192 too) by setting:

$(grep '^export XDG_' /tmp/job.sh)

sandbox output:

EOF
    echo "sandbox issue (XDG_xxx_DIR related)" > $issuedir/title
  else
    echo "sandbox issue" > $issuedir/title
  fi
  head -n 10 $sandb >> $issuedir/issue
}


# helper of ClassifyIssue()
#
function collectTestIssueResults() {
  grep -q "=$failed " /etc/portage/package.env/notest 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "=$failed notest" >> /etc/portage/package.env/notest
    try_again=1
  fi

  (
    cd "$workdir"
    # tar returns an error if it can't find a directory, therefore feed only existing dirs to it
    #
    dirs="$(ls -d ./tests ./regress ./t ./Testing ./testsuite.dir 2>/dev/null)"
    if [[ -n "$dirs" ]]; then
      tar -cjpf $issuedir/files/tests.tbz2 \
        --exclude='*.o' --exclude="*/dev/*" --exclude="*/proc/*" --exclude="*/sys/*" --exclude="*/run/*" \
        --dereference --sparse --one-file-system --warning='no-file-ignored' \
        $dirs
      local rc=$?

      if [[ $rc -ne 0 ]]; then
        rm $issuedir/files/tests.tbz2
        Mail "notice: tar failed with rc=$rc for '$failed' with dirs='$dirs'" $bak
      fi
    fi
  )
}


# helper of GotAnIssue()
# get the issue
# get an descriptive title from the most meaningful lines of the issue
# if needed: change package.env/...  to re-try failed with defaults settings
#
function ClassifyIssue() {
  touch $issuedir/{issue,title}

  # test", "compile" etc.
  #
  phase=""

  if [[ -n "$(grep -m 1 ' * Detected file collision(s):' $bak)" ]]; then
    foundCollisionIssue

  elif [[ -f $sandb ]]; then
    foundSandboxIssue

  else
    phase=$(
      grep -m 1 -A 2 " \* ERROR:.* failed (.* phase):" $bak |\
      tee $issuedir/issue                                   |\
      head -n 1                                             |\
      sed -e 's/.* failed \(.* phase\)/\1/g'                |\
      cut -f2 -d'('                                         |\
      cut -f1 -d' '
    )
    head -n 2 $issuedir/issue | tail -n 1 > $issuedir/title

    if [[ "$phase" = "test" ]]; then
      collectTestIssueResults
    fi

    # try to guess a better title & issue based on pattern files
    # the pattern order within the file is important therefore "grep -f" can't be used
    #
    cat /tmp/tb/data/CATCH_ISSUES.$phase /tmp/tb/data/CATCH_ISSUES 2>/dev/null |\
    while read c
    do
      grep -a -m 1 -B 2 -A 3 "$c" $bak > $issuedir/issue.tmp
      if [[ $? -eq 0 ]]; then
        mv $issuedir/issue.tmp $issuedir/issue
        # take 3rd line for the (new) title
        #
        sed -n '3p' < $issuedir/issue | sed -e 's,['\''‘’"`], ,g' > $issuedir/title

        # if the issue is too big, then delete 1st line
        #
        if [[ $(wc -c < $issuedir/issue) -gt 1024 ]]; then
          sed -i -e "1d" $issuedir/issue
        fi
        break
      fi
      rm $issuedir/issue.tmp
    done

    # kick off hex addresses, line and time numbers and other stuff
    #
    sed -i  -e 's/0x[0-9a-f]*/<snip>/g'         \
            -e 's/: line [0-9]*:/:line <snip>:/g' \
            -e 's/[0-9]* Segmentation fault/<snip> Segmentation fault/g' \
            -e 's/Makefile:[0-9]*/Makefile:<snip>/g' \
            -e 's,:[[:digit:]]*): ,:<snip>:,g'  \
            -e 's,([[:digit:]]* of [[:digit:]]*),(<snip> of <snip)>,g'  \
            -e 's,  *, ,g'                      \
            -e 's,[0-9]*[\.][0-9]* sec,,g'      \
            -e 's,[0-9]*[\.][0-9]* s,,g'        \
            -e 's,([0-9]*[\.][0-9]*s),,g'       \
            -e 's/ \.\.\.*\./ /g'               \
            -e 's/___*/_/g'                     \
            -e 's/; did you mean .* \?$//g'     \
            $issuedir/title

    if [[ ! -s $issuedir/title ]]; then
      Mail "warn: empty title for $failed" $bak
    fi
  fi

  if [[ "$keyword" = "stable" ]]; then
    echo -e "\n=== This is an issue at stable ===\n" >> $issuedir/issue
  fi
}


# try to match title to a tracker bug
# the BLOCKER file contains 3-line-paragraphs like:
#
#   # comment
#   <bug id>
#   <pattern>
#   ...
#
# if <pattern> is defined more than once then the first makes it
#
function SearchForBlocker() {
  block=""
  while read pattern
  do
    grep -q -E -e "$pattern" $issuedir/title
    if [[ $? -eq 0 ]]; then
      # no grep -E here, instead -F
      #
      block="-b $(grep -m 1 -B 1 -F "$pattern" /tmp/tb/data/BLOCKER | head -n 1)"
      break
    fi
  done < <(grep -v -e '^#' -e '^[1-9].*$' /tmp/tb/data/BLOCKER)     # skip comments and bug id lines
}


# put  b.g.o. findings+links into the email body
#
function SearchForAnAlreadyFiledBug() {
  bsi=$issuedir/bugz_search_items     # easier handling by using a file
  cp $issuedir/title $bsi

  # get away line numbers, certain special terms and characters
  #
  sed -i  -e 's,&<[[:alnum:]].*>,,g'  \
          -e 's,['\''‘’"`], ,g'       \
          -e 's,/\.\.\./, ,'          \
          -e 's,:[[:alnum:]]*:[[:alnum:]]*: , ,g' \
          -e 's,.* : ,,'              \
          -e 's,[<>&\*\?], ,g'        \
          -e 's,[\(\)], ,g'           \
          $bsi

  # for the file collision case: remove the package version (from the installed package)
  #
  grep -q "file collision" $bsi
  if [[ $? -eq 0 ]]; then
    sed -i -e 's/\-[0-9\-r\.]*$//g' $bsi
  fi

  # search first for the same version, then for category/package name
  # take the highest bug id, but put the summary of the newest 10 bugs into the email body
  #
  for i in $failed $short
  do
    id=$(timeout 300 bugz -q --columns 400 search --show-status $i "$(cat $bsi)" 2>> $issuedir/body | grep -e " CONFIRMED " -e " IN_PROGRESS " | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d ' ')
    if [[ -n "$id" ]]; then
      echo "CONFIRMED " >> $issuedir/bgo_result
      break
    fi

    for s in FIXED WORKSFORME DUPLICATE
    do
      id=$(timeout 300 bugz -q --columns 400 search --show-status --resolution "$s" --status RESOLVED $i "$(cat $bsi)" 2>> $issuedir/body | sort -u -n -r | head -n 10 | tee -a $issuedir/body | head -n 1 | cut -f1 -d ' ')
      if [[ -n "$id" ]]; then
        echo "$s " >> $issuedir/bgo_result
        break 2
      fi
    done
  done
}


# compile a command line ready for copy+paste to file a bug
# and add the top 20 b.g.o. search results too
#
function AddBugzillaData() {
  if [[ -n "$id" ]]; then
    cat << EOF >> $issuedir/body
  https://bugs.gentoo.org/show_bug.cgi?id=$id

  bgo.sh -d ~/img?/$name/$issuedir -i $id -c 'got at the $keyword amd64 chroot image $name this : $(cat $issuedir/title)'

EOF
  else
    cat << EOF >> $issuedir/body

  bgo.sh -d ~/img?/$name/$issuedir $block

EOF
    h='https://bugs.gentoo.org/buglist.cgi?query_format=advanced&short_desc_type=allwordssubstr'
    g='stabilize|Bump| keyword| bump'

    echo "  OPEN:     ${h}&resolution=---&short_desc=${short}" >> $issuedir/body
    timeout 300 bugz --columns 400 -q search --show-status      $short 2>> $issuedir/body | grep -v -i -E "$g" | sort -u -n -r | head -n 20 >> $issuedir/body

    echo "" >> $issuedir/body
    echo "  RESOLVED: ${h}&bug_status=RESOLVED&short_desc=${short}" >> $issuedir/body
    timeout 300 bugz --columns 400 -q search --status RESOLVED  $short 2>> $issuedir/body | grep -v -i -E "$g" | sort -u -n -r | head -n 20  >> $issuedir/body
  fi

  # this newline makes a manual copy+paste action more convenient
  #
  echo >> $issuedir/body
}


# b.g.o. has a limit for "Summary" of 255 chars
#
function TrimTitle()  {
  n=${1:-255}

  if [[ $(wc -c < $issuedir/title) -gt $n ]]; then
    truncate -s $n $issuedir/title
  fi
}


# helper of GotAnIssue()
# create an email containing convenient links and a command line ready for copy+paste
#
function CompileIssueMail() {
  emerge -p --info $short &> $issuedir/emerge-info.txt

  # shrink too long error messages
  #
  sed -i -e 's,/[^ ]*\(/[^/:]*:\),/...\1,g' $issuedir/title

  SearchForBlocker

  # the upper limit is 16 KB at b.g.o.
  #
  while [[ $(wc -c < $issuedir/issue) -gt 12000 ]]
  do
    sed -i '1d' $issuedir/issue
  done

  # copy issue to the email body before enhancing it further to become comment#0
  #
  cp $issuedir/issue $issuedir/body
  AddWhoamiToIssue

  AddMetainfoToBody

  # report languages and compilers
  #
  cat << EOF >> $issuedir/issue
gcc-config -l:
$(gcc-config -l                   )
$( [[ -x /usr/bin/llvm-config ]] && echo llvm-config: && llvm-config --version )
$(eselect python  list 2>/dev/null)
$(eselect ruby    list 2>/dev/null)
$( [[ -x /usr/bin/java-config ]] && echo java-config: && java-config --list-available-vms --nocolor )
$(eselect java-vm list 2>/dev/null)

emerge -qpv $short
$(emerge -qpv $short 2>/dev/null)
EOF

  if [[ -s $issuedir/title ]]; then
    TrimTitle 200
    SearchForAnAlreadyFiledBug
    AddBugzillaData
  fi

  AttachFilesToBody $issuedir/emerge-info.txt $issuedir/files/* $issuedir/_*

  if [[ "$phase" = "test" ]]; then
    sed -i -e "s,^,$failed : [TEST] ," $issuedir/title
  else
    sed -i -e "s,^,$failed : ," $issuedir/title
  fi
  TrimTitle

  # give write perms to non-root/portage user too
  #
  chmod    777  $issuedir/{,files}
  chmod -R a+rw $issuedir/
}


# helper of GotAnIssue()
# guess the failed package name and its log file name
#
function setFailedAndShort()  {
  failedlog=$(grep -m 1 "The complete build log is located at" $bak | cut -f2 -d"'" -s)
  if [[ -z "$failedlog" ]]; then
    failedlog=$(grep -m 1 -A 1 "', Log file:" $bak | tail -n 1 | cut -f2 -d"'" -s)
    if [[ -z "$failedlog" ]]; then
      failedlog=$(grep -m 1 "^>>>  '" $bak | cut -f2 -d"'" -s)
    fi
  fi

  if [[ -n "$failedlog" ]]; then
    failed=$(basename $failedlog | cut -f1-2 -d':' -s | tr ':' '/')
  else
    failed="$(cd /var/tmp/portage; ls -1d */* 2>/dev/null)"
    if [[ -n "$failed" ]]; then
      failedlog=$(ls -1t /var/log/portage/$(echo "$failed" | tr '/' ':'):????????-??????.log 2>/dev/null | head -n 1)
    else
      failed=$(grep -m1 -F ' * Package:    ' | awk ' { print $3 } ' $bak)
    fi
  fi

  short=$(pn2p "$failed")
  if [[ ! -d /usr/portage/$short ]]; then
    failed=""
    short=""
  fi
}


# helper of GotAnIssue() and CheckQA
#
function SendoutIssueMail()  {
  # no matching pattern in CATCH_* == no title
  #
  if [[ -s $issuedir/title ]]; then
    # do not report the same issue again
    #
    grep -F -q -f $issuedir/title /tmp/tb/data/ALREADY_CATCHED
    if [[ $? -eq 0 ]]; then
      return
    fi

    cat $issuedir/title >> /tmp/tb/data/ALREADY_CATCHED
  fi

  # $issuedir/bgo_result might not exists
  #
  Mail "$(cat $issuedir/bgo_result 2>/dev/null)$(cat $issuedir/title)" $issuedir/body
}


# helper of GotAnIssue()
# add successfully emerged dependencies of $task to the world file
# otherwise we'd need to use "--deep" unconditionally
# (https://bugs.gentoo.org/show_bug.cgi?id=563482)
#
function PutDepsInWorld() {
  line=$(tac /var/log/emerge.log | grep -m 1 -E ':  === |: Started emerge on: ')
  echo "$line" | grep -q ':  === ('
  if [[ $? -eq 0 ]]; then
    echo "$line" | grep -q ':  === (1 of '
    if [[ $? -eq 1 ]]; then
      emerge --depclean --pretend --verbose=n 2>/dev/null | grep "^All selected packages: " | cut -f2- -d':' -s |\
      while read p
      do
        # add only the minimal needed subset of dependencies of $task
        # https://wiki.gentoo.org/wiki/World_set_(Portage)
        #
        if [[ -n "$(qdepends -Q $p 2>/dev/null)" ]]; then
          if [[ -z "$(emerge -p --quiet --depclean $p 2>/dev/null)" ]]; then
            emerge --noreplace $p &>/dev/null
          fi
        fi
      done
    fi
  fi
}


# helper of GotAnIssue()
# for ABI_X86="32 64" we have two ./work directories in /var/tmp/portage/<category>/<name>
#
function setWorkDir() {
  workdir=$(fgrep -m 1 " * Working directory: '" $bak | cut -f2 -d"'" -s)
  if [[ ! -d "$workdir" ]]; then
    workdir=$(fgrep -m 1 ">>> Source unpacked in " $bak | cut -f5 -d" " -s)
    if [[ ! -d "$workdir" ]]; then
      workdir=/var/tmp/portage/$failed/work/$(basename $failed)
      if [[ ! -d "$workdir" ]]; then
        workdir=""
      fi
    fi
  fi
}


# collect files, create an email and decide, whether to send it out or not
#
function GotAnIssue()  {
  PutDepsInWorld

  fatal=$(grep -f /tmp/tb/data/FATAL_ISSUES $bak)
  if [[ -n "$fatal" ]]; then
    Finish 1 "FATAL: $fatal"
  fi

  grep -q -e "Exiting on signal" -e " \* The ebuild phase '.*' has been killed by signal" $bak
  if [[ $? -eq 0 ]]; then
    Finish 1 "KILLED"
  fi

  grep -q -e 'AssertionError: ebuild not found for' -e 'portage.exception.FileNotFound:' $bak
  if [[ $? -eq 0 ]]; then
    echo "$task" >> $backlog
    sleep 30  # race with repo updated should be over
    return
  fi

  grep -q -f /tmp/tb/data/IGNORE_ISSUES $bak
  if [[ $? -eq 0 ]]; then
    return
  fi

  setFailedAndShort
  if [[ -z "$failed" ]]; then
    Mail "warn: \$failed is empty, task: '$task'" $bak
    return
  fi

  CreateIssueDir
  GetAssigneeAndCc
  cp $bak $issuedir
  setWorkDir
  CollectIssueFiles
  ClassifyIssue

  # ttps://bugs.gentoo.org/463976 https://bugs.gentoo.org/640866 https://bugs.gentoo.org/582046
  #
  grep -q -e "Can't locate .* in @INC" -e "configure: error: perl module Locale::gettext required" $bak
  if [[ $? -eq 0 ]]; then
    try_again=1   # just to not fall in the ==0 code path in WorkOnTask()
    cat << EOF >> $backlog
$task
%perl-cleaner --all
EOF
    return
  fi

  if [[ $try_again -eq 1 ]]; then
    echo "$task" >> $backlog
  else
    echo "=$failed" >> /etc/portage/package.mask/self
  fi

  CompileIssueMail
  SendoutIssueMail
}


# helper of PostEmerge()
# certain packages depend on *compiled* kernel modules
#
function BuildKernel()  {
  (
    eval $(grep -e ^CC= /etc/portage/make.conf)
    export CC

    cd /usr/src/linux     &&\
    make defconfig        &&\
    make modules_prepare  &&\
    make                  &&\
    make modules_install  &&\
    make install
  ) &>> $log

  return $?
}


# helper of PostEmerge()
# switch to highest GCC version
#
function SwitchGCC() {
  latest=$(gcc-config --list-profiles --nocolor | cut -f3 -d' ' -s | grep 'x86_64-pc-linux-gnu-.*[0-9]$' | tail -n 1)
  gcc-config --list-profiles --nocolor | grep -q "$latest \*$"
  if [[ $? -eq 1 ]]; then
    verold=$(gcc -dumpversion)
    gcc-config --nocolor $latest &>> $log
    source /etc/profile

    # get rid of the old compilers, increase chances to catch issues
    #
    cat << EOF >> $backlog
%emerge --unmerge sys-devel/gcc:$verold
EOF

    # rebuild kernel and toolchain after a major version number change
    #
    vernew=$(gcc -dumpversion)
    majold=$(echo $verold | cut -c1)
    majnew=$(echo $vernew | cut -c1)
    if [[ "$majold" != "$majnew" ]]; then
%fix_libtool_files.sh $verold
%revdep-rebuild --ignore --library libstdc++.so.6 -- --exclude gcc
EOF
      # without a rebuild we'd get issues like: "cc1: error: incompatible gcc/plugin versions"
      # therefore clean the old object files
      #
      if [[ -e /usr/src/linux/.config ]]; then
        (cd /usr/src/linux && make clean &>/dev/null)
        echo "%BuildKernel" >> $backlog
      fi
    fi
  fi
}


# helper of setNextTask()
# choose an arbitrary system java engine
#
function SwitchJDK()  {
  old=$(eselect java-vm show system 2>/dev/null | tail -n 1 | xargs)
  if [[ -n "$old" ]]; then
    new=$(
      eselect java-vm list 2>/dev/null |\
      grep -e ' oracle-jdk-[[:digit:]] ' -e ' icedtea[-bin]*-[[:digit:]] ' |\
      grep -v " icedtea-bin-[[:digit:]].*-x86 " |\
      grep -v ' system-vm' |\
      awk ' { print $2 } ' | sort --random-sort | head -n 1
    )
    if [[ -n "$new" && "$new" != "$old" ]]; then
      eselect java-vm set system $new 1>> $log
    fi
  fi
}


# helper of RunAndCheck()
# it schedules follow-ups from the last emerge operation
#
function PostEmerge() {
  # prefix our log backup file with an "_" to distinguish it from portages log file
  #
  bak=/var/log/portage/_emerge_$(date +%Y%m%d-%H%M%S).log
  stresc < $log > $bak

  # don't change these config files after image setup
  #
  rm -f /etc/._cfg????_{hosts,resolv.conf}
  rm -f /etc/ssmtp/._cfg????_ssmtp.conf
  rm -f /etc/portage/._cfg????_make.conf
  ls /etc/._cfg????_locale.gen &>/dev/null
  if [[ $? -eq 0 ]]; then
    echo "%locale-gen" >> $backlog
    rm /etc/._cfg????_locale.gen
  fi

  etc-update --automode -5 1>/dev/null
  env-update &>/dev/null
  source /etc/profile || Finish 2 "can't source /etc/profile"

  # one of the very last step in upgrading
  #
  grep -q "Use emerge @preserved-rebuild to rebuild packages using these libraries" $bak
  if [[ $? -eq 0 ]]; then
    echo "@preserved-rebuild" >> $backlog
  fi

  # build and switch to the new kernel after nearly all other things
  #
  grep -q ">>> Installing .* sys-kernel/.*-sources" $bak
  if [[ $? -eq 0 ]]; then
    last=$(ls -1dt /usr/src/linux-* | head -n 1 | cut -f4 -d'/' -s)
    link=$(eselect kernel show | tail -n 1 | sed -e 's/ //g' | cut -f4 -d'/' -s)
    if [[ "$last" != "$link" ]]; then
      eselect kernel set $last
    fi

    if [[ ! -f /usr/src/linux/.config ]]; then
      echo "%BuildKernel" >> $backlog
    fi
  fi

  grep -q -e "Please, run 'haskell-updater'" -e "ghc-pkg check: 'checking for other broken packages:'" $bak
  if [[ $? -eq 0 ]]; then
    echo "%haskell-updater" >> $backlog
  fi

  # Perl still needs love
  #
  grep -q ">>> Installing .* sys-lang/perl-[1-9]" $bak
  if [[ $? -eq 0 ]]; then
    echo "%perl-cleaner --all" >> $backlog
  fi

  # switch to a new GCC soon
  #
  grep -q ">>> Installing .* sys-devel/gcc-[1-9]" $bak
  if [[ $? -eq 0 ]]; then
    echo "%SwitchGCC" >> $backlog
  fi

  # if $backlog is empty then do 24 hours after the last time:
  #   - update @world
  #   - update @system + switch java VM + sync image specific overlays
  #
  if [[ ! -s $backlog ]]; then
    if [[ -f /tmp/@world.history ]]; then
      let "diff = $(date +%s) - $(date +%s -r /tmp/@world.history)"
      if [[ $diff -gt 86400 ]]; then
        echo "@world" >> $backlog
      fi
    fi

    if [[ -f /tmp/@system.history ]]; then
      let "diff = $(date +%s) - $(date +%s -r /tmp/@system.history)"
      if [[ $diff -gt 86400 ]]; then
        cat << EOF >> $backlog
@system
%SwitchJDK
EOF
        grep -q "^auto-sync *= *yes$" /etc/portage/repos.conf/*
        if [[ $? -eq 0 ]]; then
          echo "%emerge --sync" >> $backlog
        fi
      fi
    fi
  fi
}


# helper of RunAndCheck()
#
function CheckQA() {
  f=/tmp/qafilenames

  # process all elog files created after the last call of this function
  #
  if [[ -f $f ]]; then
    find /var/log/portage/elog -name '*.log' -newer $f  > $f.tmp
  else
    find /var/log/portage/elog -name '*.log'            > $f.tmp
  fi
  mv $f.tmp $f

  # process each QA issue independent from all others even for the same QA file
  #
  cat $f |\
  while read elogfile
  do
    cat /tmp/tb/data/CATCH_QA |\
    while read reason
    do
      grep -q "$reason" $elogfile
      if [[ $? -eq 0 ]]; then
        failed=$(basename $elogfile | cut -f1-2 -d':' -s | tr ':' '/')
        short=$(pn2p "$failed")

        CreateIssueDir

        GetAssigneeAndCc

        cp $elogfile $issuedir/issue
        AddWhoamiToIssue

        echo "$reason" > $issuedir/title
        SearchForBlocker

        grep -A 10 "$reason" $issuedir/issue > $issuedir/body
        AddMetainfoToBody

        echo -e "\nbgo.sh -d ~/img?/$name/$issuedir -s QA $block\n" >> $issuedir/body
        id=$(timeout 300 bugz -q --columns 400 search --show-status $short "$reason" 2>> $issuedir/body | sort -u -n | tail -n 1 | tee -a $issuedir/body | cut -f1 -d ' ')

        AttachFilesToBody $issuedir/issue

        sed -i -e "s,^,$failed : [QA] ," $issuedir/title
        TrimTitle

        if [[ -z "$id" ]]; then
          SendoutIssueMail
        fi
      fi
    done
  done
}


# helper of WorkOnTask()
# run the command ($1) and act on the output/result
#
function RunAndCheck() {
  ($1) &>> $log
  local rc=$?

  PostEmerge
  CheckQA

  if [[ $rc -ne 0 ]]; then
    GotAnIssue
  fi

  return $rc
}


# this is the heart of the tinderbox
#
function WorkOnTask() {
  failed=""     # hold the failed package name
  try_again=0   # 1 with default environment values (if applicable)

  # @system, @world, @preserved-rebuild
  #
  if [[ $task =~ ^@ ]]; then
    if [[ $task = "@system" ]]; then
      opts="--update --newuse --changed-use --changed-deps=y --deep"
    elif [[ $task = "@world" ]]; then
      opts="--update --newuse --changed-use --changed-deps=y"
    else
      opts=""
    fi
    RunAndCheck "emerge $opts $task"
    local rc=$?

    cp $log /tmp/$task.last.log
    /usr/bin/pfl &> /dev/null

    # "ok|NOT ok|<other>" is used in check_history() of whatsup.sh
    # to display " ", "[SWP]" or "[swp]" respectively
    #
    msg=$(grep -m 1 -e 'The following REQUIRED_USE flag constraints are unsatisfied:' \
                    -e 'The following USE changes are necessary'    \
                    -e 'The following update has been skipped'      \
                    -e 'WARNING: One or more updates/rebuilds'      \
                    -e 'Multiple package instances within a single package slot have been pulled' \
        $bak)

    if [[ $rc -ne 0 ]]; then
      echo "$(date) NOT ok ${failed:-$msg}" >> /tmp/$task.history

      if [[ $try_again -eq 0 ]]; then
        if [[ -n "$failed" ]]; then
          echo "%emerge --resume --skip-first" >> $backlog
        elif [[ "$task" = "@preserved-rebuild" ]]; then
          Finish 3 "task $task failed"
        fi
      fi

    else
      echo "$(date) ${msg:-ok}" >> /tmp/$task.history
    fi

  # %revdep-rebuild, %switch2libressl.sh, resuming
  #
  elif [[ $task =~ ^% ]]; then
    cmd="$(echo "$task" | cut -c2-)"
    RunAndCheck "$cmd"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
      if [[ $try_again -eq 0 ]]; then
        if [[ $task =~ " --resume" ]]; then
          if [[ -n "$failed" ]]; then
            echo "%emerge --resume --skip-first" >> $backlog
          else
            grep -q ' Invalid resume list:' $bak
            if [[ $? -eq 0 ]]; then
              cat << EOF >> $backlog
@world
@system
EOF
            else
              Finish 3 "resume failed"
            fi
          fi
        else
          Finish 3 "command: '$cmd'"
        fi
      fi
    fi

  # pinned version
  #
  elif [[ $task =~ ^= ]]; then
    p="$(echo "$task" | cut -c2-)"
    RunAndCheck "emerge $p"

  # straight atom
  #
  else
    RunAndCheck "emerge --update $task"
  fi
}


# hook, eg. to catch install artefacts
#
function pre-check() {
  exe=/tmp/pre-check.sh
  out=/tmp/pre-check.log

  if [[ ! -x $exe ]]; then
    return
  fi

  $exe &> $out
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    rm $out

  elif [[ $rc -gt 127 ]]; then
    Mail "$exe returned $rc, task $task" $out
    Finish 2 "error: stopped"

  else
    cat << EOF >> $out

--
seen at tinderbox image $name
$log:
$( tail -n 30 $log 2>/dev/null )

--
emerge --info:
$( emerge --info --verbose=n $task 2>&1 )
EOF
    Mail "$exe : rc=$rc, task $task" $out
  fi
}


#############################################################################
#
#       main
#
mailto="tinderbox@zwiebeltoralf.de"
tsk=/tmp/task                       # holds the current task
log=$tsk.log                        # holds always output of the running task command
backlog=/tmp/backlog.1st            # this is the high prio backlog

export GCC_COLORS=""                # suppress colour output of gcc-4.9 and above
export GREP_COLORS="never"

# eg.: gnome_20150913-104240
#
name=$(grep '^PORTAGE_ELOG_MAILFROM="' /etc/portage/make.conf | cut -f2 -d '"' -s | cut -f1 -d ' ')

# needed for the b.g.o. comment #0
#
keyword="stable"
grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
if [[ $? -eq 0 ]]; then
  keyword="unstable"
fi

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

while :
do
  pre-check
  date > $log

  # auto-clean is deactivated to collect issue files
  #
  rm -rf /var/tmp/portage/*

  setNextTask
  echo "$task" | tee -a $tsk.history > $tsk
  chmod a+w $tsk
  WorkOnTask

  # hint: we don't reach this line if Finish() occurs in WorkOnTask()
  # therefore $tsk is repeated at next start
  #
  rm $tsk
done
