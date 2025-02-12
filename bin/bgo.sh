#!/bin/bash
# set -x

# create or modify a bug report at http://bugzilla.gentoo.org

function Warn() {
  local rc=$?

  echo "--------------"
  echo -e "\n  ${1:-} failed with error code $rc\n\n"
  tail -v bgo.sh.*
  echo "--------------"
}


function Exit() {
  local rc=${1:-$?}

  trap - INT QUIT TERM EXIT

  if [[ $rc -ne 0 ]]; then
    Warn $rc
  fi
  exit $rc
}


#######################################################################

set -eu
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/tb/bin"
export LANG=C.utf8

id=""
block=""
comment=""
issuedir=""
severity="Normal"

newbug=1    # if set to 1 then do neither change To: nor cc:

while getopts b:c:d:i:s: opt
do
  case $opt in
    b)  block="$OPTARG";;       # (b)lock that bug (id or alias)
    c)  comment="$OPTARG";;     # (c)omment, used with -a
    d)  issuedir="$OPTARG";;    # (d)irectory with all files
    i)  id="$OPTARG"            # (i)d of an existing bug
        newbug=0
        ;;
    s)  severity="$OPTARG";;    # "normal", "QA" and so on
    *)  echo "unknown parameter '${opt}'"; exit 1;;
  esac
done

if [[ -z "$issuedir" ]]; then
  echo "no issuedir given"
  exit 1
fi

cd $issuedir

if [[ -f ./.reported ]]; then
  echo -e "\n already reported, for a re-run do:\n\n    rm $issuedir/.reported\n"
  exit 3
fi

trap Exit INT QUIT TERM EXIT

# cleanup of a previous run
rm -f bgo.sh.{out,err}

if [[ -n "$id" ]]; then
  # modify an existing bug report
  if [[ -z "$comment" ]]; then
    comment="appeared recently at the tinderbox image $(realpath $issuedir | cut -f5 -d'/')"
  fi
  timeout 60 bugz modify --status CONFIRMED --comment "$comment" $id 1>bgo.sh.out 2>bgo.sh.err

else
  if [[ ! -s ./assignee ]]; then
    echo "no assignee given, run check_bgo.sh before !"
    exit 4
  fi

  # create a new bug report
  timeout 60 bugz post \
    --product "Gentoo Linux"          \
    --component "Current packages"    \
    --version "unspecified"           \
    --title "$(cat ./title)"          \
    --op-sys "Linux"                  \
    --platform "All"                  \
    --priority "Normal"               \
    --severity "$severity"            \
    --alias ""                        \
    --description-from "./comment0"   \
    --batch                           \
    --default-confirm n               \
    1>bgo.sh.out 2>bgo.sh.err

  id=$(grep "Info: Bug .* submitted" bgo.sh.out | sed 's/[^0-9]//g')
  if [[ -z "$id" ]]; then
    echo
    echo "empty bug id"
    echo
    Exit 4
  fi

  if [[ -n "$comment" ]]; then
    timeout 60 bugz modify --status CONFIRMED --comment "$comment" $id 1>bgo.sh.out 2>bgo.sh.err
  fi

  if grep -q -F ' fails test -' $issuedir/title; then
    timeout 60 bugz modify --set-keywords "TESTFAILURE" $id 1>bgo.sh.out 2>bgo.sh.err || Warn "test keyword"
  fi
fi
echo

# avoid duplicate reports
echo "https://bugs.gentoo.org/show_bug.cgi?id=$id" | tee -a ./.reported

if [[ -s bgo.sh.err ]]; then
  Exit 5
fi

if [[ -f emerge-info.txt ]]; then
  timeout 60 bugz attach --content-type "text/plain" --description "" $id emerge-info.txt 1>bgo.sh.out 2>bgo.sh.err || Warn "info"
fi

if [[ -d ./files ]]; then
  echo
  for f in ./files/*
  do
    bytes=$(wc --bytes < $f)
    if [[ $bytes -eq 0 ]]; then
      echo "skipped empty file: $f"
      continue
    # max. size from b.g.o. is 1000 KB
    elif [[ $bytes -gt 1000000 ]]; then
      echo "too fat file: $f"
      file_size=$(ls -lh $f | awk ' { print $5 } ')
      file_path=$(realpath $f | sed -e "s,^.*img/,,g")
      url="http://tinderbox.zwiebeltoralf.de:31560/$file_path"
      comment="The file size of $f is too big ($file_size) for an upload. For about 8 weeks the link $url is valid."
      timeout 60 bugz modify --comment "$comment" $id 1>bgo.sh.out 2>bgo.sh.err
      continue
    fi

    if grep -q -e "bz2$" -e "xz$" <<< $f; then
      ct="application/x-bzip"
    else
      ct="text/plain"
    fi
    echo "  $f"
    timeout 60 bugz attach --content-type "$ct" --description "" $id $f 1>bgo.sh.out 2>bgo.sh.err || Warn "attach $f"
  done
fi

if [[ -n "$block" ]]; then
  timeout 60 bugz modify --add-blocked "$block" $id 1>bgo.sh.out 2>bgo.sh.err || Warn "blocker $block"
fi

# do this as the very last step to reduce the amount of emails sent out by bugzilla for each record change
if [[ $newbug -eq 1 ]]; then
  name=$(cat $issuedir/../../name)
  assignee="$(cat ./assignee)"
  if [[ $name =~ musl && $assignee != "maintainer-needed@gentoo.org" ]] && ! grep -q -f ~tinderbox/tb/data/CATCH_MISC $issuedir/title; then
    assignee="musl@gentoo.org"
    cc="$(cat ./assignee ./cc 2>/dev/null | xargs -n 1 | grep -v "musl@gentoo.org" | xargs)"
  else
    cc="$(cat ./cc 2>/dev/null || true)"
  fi
  add_cc=""
  if [[ -n "$cc" ]]; then
    add_cc="--add-cc $(sed 's, , --add-cc ,g' <<< $cc)"
  fi

  timeout 60 bugz modify -a $assignee $add_cc $id 1>bgo.sh.out 2>bgo.sh.err || Warn "'$assignee' '$add_cc'"
fi

echo
