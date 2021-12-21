#!/bin/bash
# set -x

# crontab example:
# * * * * * /opt/tb/bin/logcheck.sh

set -eu
export LANG=C.utf8

f=/tmp/$(basename $0).out
n=$(wc -l < <(cat ~tinderbox/logs/*.log 2>/dev/null)

if [[ ! -s $f ]]; then
  if [[ $n -gt 0 ]]; then
    (
      ls -l ~tinderbox/logs/
      echo
      head -v ~tinderbox/logs/*.log | tee $f
      echo
      echo -e "\n\nto re-activate this test again, do:\n\n  tail -v ~tinderbox/logs/*; rm -f $f;     truncate -s 0 ~tinderbox/logs/*\n\n"
    ) | mail -s "INFO: tinderbox logs" ${MAILTO:-tinderbox}
  fi
else
  # remove obsolete old file
  if [[ $n -eq 0 ]]; then
    rm $f
  fi
fi
