#!/bin/sh
#
# set -x

# switch a tinderbox image from OpenSSL to LibeSSL
# inspired by https://wiki.gentoo.org/wiki/Project:LibreSSL
#

pks="/tmp/packages"

echo
echo "=================================================================="
echo

if [[ ! -e $pks ]]; then
  echo " don't run this script outside of a tinderbox image !"
  exit 21
fi

# define the SSL vendor in make.conf
#
# CURL_SSL="libressl"
# USE="
#   -openssl -gnutls libressl
# ...
#
sed -i  -e '/^CURL_SSL="/d'           \
        -e 's/ [+-]*openssl[ ]*/ /'   \
        -e 's/ [+-]*libressl[ ]*/ /'  \
        -e 's/ [+-]*gnutls[ ]*/ /'    \
        -e 's/USE="/CURL_SSL="libressl"\nUSE="\n  -openssl -gnutls libressl\n  /' \
        /etc/portage/make.conf || exit 22

mkdir -p /etc/portage/profile || exit 23

# mask OpenSSL forever
#
echo "dev-libs/openssl" > /etc/portage/package.mask/openssl || exit 24

# unmask LibreSSL related USE flags
#
cat << EOF >> /etc/portage/profile/use.stable.mask || exit 25
-libressl
-curl_ssl_libressl
EOF

# switch to LibeSSL often fails w/o these settings
#
cat << EOF > /etc/portage/package.use/libressl || exit 26
dev-db/mysql-connector-c  -ssl
dev-lang/python           -tk
dev-qt/qtsql              -mysql
EOF

# few unstable packages need being keyworded at a stable tinderbox image
# too beside libressl itself
#
grep -q '^ACCEPT_KEYWORDS=.*~amd64' /etc/portage/make.conf
if [[ $? -eq 1 ]]; then
  cat << EOF > /etc/portage/package.accept_keywords/libressl || exit 27
dev-libs/libressl
~mail-mta/ssmtp-2.64-r3
EOF

fi

# fetch packages before openssl is uninstalled
# (and wget won't work before it is rebuilt agains libressl)
#
emerge -f dev-libs/libressl net-misc/openssh mail-mta/ssmtp net-misc/wget dev-lang/python || exit 28

# unmerge of OpenSSL should already schedule a @preserved-rebuild in the script job.sh
# but force it here too with "%" to eventually bail out if that task fails
#
cat << EOF >> $pks
%emerge @preserved-rebuild
%emerge -C openssl

EOF

exit 0
