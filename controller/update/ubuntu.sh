#!/bin/bash
#
# Update the upgrade script for nanobox

# exit if any any command fails
set -e

set -o pipefail

# create temp file
TMPFILE=$(mktemp)

cleanup() {
  # cleanup temp file
  rm -rf ${TMPFILE}
}

trap cleanup EXIT


download_upgrade() {
  # download file
  curl -s https://s3.amazonaws.com/unity.nanobox.io/bootstrap/controller/ubuntu/upgrade > ${TMPFILE}
}

download_checksum() {
  # download checksum
  curl -s https://s3.amazonaws.com/unity.nanobox.io/bootstrap/controller/ubuntu/upgrade.md5
}

checksum_file() {
  # checksum file
  cat $TMPFILE | md5sum | awk '{print $1}'
}

install_file() {
  # move into place if checksums match
  if [ "$(download_checksum)" = "$(checksum_file)" ]; then
  	cp $TMPFILE /usr/bin/nanobox-upgrade
  fi
}

download_upgrade
install_file