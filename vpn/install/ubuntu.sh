#!/bin/bash
#
# Upgrade the nanobox environment on the system.

# exit if any any command fails
set -e

set -o pipefail

# cleanup() {
#   echo "cleanup"
# }

# trap cleanup EXIT

# source current settings

if [ -f /etc/openvpn/easy-rsa/vars ]; then
  . /etc/openvpn/easy-rsa/vars
fi

wait_for_lock() {
  # wait to make sure no package updates are currently running, it'll break the bootstrap script if it is running.
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 ; do
    sleep 1
  done
}

apt_install() {
  PROGRAM=$1
  PACKAGE=$2
  which $1 > /dev/null || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install $2 )
}

install_packages() {
  apt_install openvpn openvpn
  apt_install /usr/share/easy-rsa/build-ca easy-rsa
  apt_install rsync rsync
  apt_install rngd rng-tools
}

apt_update_upgrade() {
  wait_for_lock; apt-get update
  wait_for_lock; apt-get upgrade
}

rsync_easy_rsa() {
  [ -d /etc/openvpn/easy-rsa ] || mkdir /etc/openvpn/easy-rsa/
  rsync -a --exclude=vars /usr/share/easy-rsa/ /etc/openvpn/easy-rsa/
}

prompt_user() {
  local VARIABLE=$1
  local MESSAGE="$2"
  while [ -z ${!VARIABLE} ]; do
    read -p "${MESSAGE}" ${VARIABLE}
  done
}

ensure_variables_have_values() {
  echo "Setting up variables for the Certificate Authority:"
  prompt_user KEY_COUNTRY "Enter the country code (e.g. US, CA, AU): "
  prompt_user KEY_PROVINCE "Enter the state/province name (e.g Idaho, Alberta, Queensland): "
  prompt_user KEY_CITY "Enter the city name (e.g Rexburg, Aetna, Nebo): "
  prompt_user KEY_ORG "Enter the organization name (e.g Nanobox): "
  prompt_user KEY_EMAIL "Enter the administrator email (e.g admin@nanobox.io): "
  prompt_user KEY_CN "Enter the common name (e.g unity.nanobox.io): "
  prompt_user KEY_NAME "Enter the name (e.g openvpn): "
  prompt_user KEY_ALTNAMES "Enter the name (e.g vpn.unity.nanobox.io): "
  prompt_user KEY_OU "Enter the organizational unit (e.g web): "
}

easy_rsa_vars_file() {
  cat <<'END'
# easy-rsa parameter settings

# NOTE: If you installed from an RPM,
# don't edit this file in place in
# /usr/share/openvpn/easy-rsa --
# instead, you should copy the whole
# easy-rsa directory to another location
# (such as /etc/openvpn) so that your
# edits will not be wiped out by a future
# OpenVPN package upgrade.

# This variable should point to
# the top level of the easy-rsa
# tree.
export EASY_RSA="`pwd`"

#
# This variable should point to
# the requested executables
#
export OPENSSL="openssl"
export PKCS11TOOL="pkcs11-tool"
export GREP="grep"


# This variable should point to
# the openssl.cnf file included
# with easy-rsa.
export KEY_CONFIG=`$EASY_RSA/whichopensslcnf $EASY_RSA`

# Edit this variable to point to
# your soon-to-be-created key
# directory.
#
# WARNING: clean-all will do
# a rm -rf on this directory
# so make sure you define
# it correctly!
export KEY_DIR="$EASY_RSA/keys"

# Issue rm -rf warning
echo NOTE: If you run ./clean-all, I will be doing a rm -rf on $KEY_DIR

# PKCS11 fixes
export PKCS11_MODULE_PATH="dummy"
export PKCS11_PIN="dummy"

# Increase this to 2048 if you
# are paranoid.  This will slow
# down TLS negotiation performance
# as well as the one-time DH parms
# generation process.
export KEY_SIZE=2048

# In how many days should the root CA key expire?
export CA_EXPIRE=3650

# In how many days should certificates expire?
export KEY_EXPIRE=3650

# These are the default values for fields
# which will be placed in the certificate.
# Don't leave any of these fields blank.
END
  cat <<END
export KEY_COUNTRY=${KEY_COUNTRY}
export KEY_PROVINCE=${KEY_PROVINCE}
export KEY_CITY=${KEY_CITY}
export KEY_ORG=${KEY_ORG}
export KEY_EMAIL=${KEY_EMAIL}
export KEY_OU=${KEY_OU}
# X509 Subject Field
export KEY_NAME=${KEY_NAME}
export KEY_ALTNAMES=${KEY_ALTNAMES}

# PKCS11 Smart Card
# export PKCS11_MODULE_PATH="/usr/lib/changeme.so"
# export PKCS11_PIN=1234

# If you'd like to sign all keys with the same Common Name, uncomment the KEY_CN export below
# You will also need to make sure your OpenVPN server config has the duplicate-cn option set
export KEY_CN=${KEY_CN}
END
}

create_keys_dir() {
  [ -d /etc/openvpn/easy-rsa/keys ] || (cd /etc/openvpn/easy-rsa; source vars; ./clean-all)
}

generate_ca() {
  [ -f /etc/openvpn/easy-rsa/keys/ca.crt ] || (cd /etc/openvpn/easy-rsa; source vars; ./build-ca)
}

generate_dh() {
  [ -f /etc/openvpn/easy-rsa/keys/dh2048.pem ] || (cd /etc/openvpn/easy-rsa; source vars; ./build-dh)
} 

generate_server_certificate() {
  [ -f /etc/openvpn/easy-rsa/keys/${KEY_NAME}.crt ] || (cd /etc/openvpn/easy-rsa; source vars; ./build-key-server $KEY_NAME )
}

configure_easy_rsa() {
  ensure_variables_have_values
  rsync_easy_rsa
  echo "$(easy_rsa_vars_file)" > /etc/openvpn/easy-rsa/vars
  create_keys_dir
  generate_ca
  generate_dh
  generate_server_certificate
}

apt_update_upgrade
install_packages
configure_easy_rsa
