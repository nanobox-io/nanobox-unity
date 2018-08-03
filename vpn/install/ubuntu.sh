#!/bin/bash
#
# Upgrade the nanobox environment on the system.

# exit if any any command fails
set -e

set -o pipefail

TMPFILE=$(mktemp)

cleanup() {
  rm -rf ${TMPFILE}
}

trap cleanup EXIT

# source current settings

if [ -f /etc/openvpn/easy-rsa/vars ]; then
  . /etc/openvpn/easy-rsa/vars
fi

init_system() {
  if [[ -f /sbin/systemctl || -f /bin/systemctl ]]; then
    echo "systemd"
  elif [[ -f /sbin/initctl || -f /bin/initctl ]]; then
    echo "upstart"
  else
    echo "sysvinit"
  fi
}

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
  wait_for_lock; apt-get -y update
  wait_for_lock; apt-get -y upgrade
}

configure_sysctl() {
  sed -i -e 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
  sysctl -p
}

build_firewall() {
  cat <<END
#!/bin/bash

if [ ! -f /run/iptables ]; then
  # flush the current firewall
  iptables -F

  # Set default policies (nothing in, anything out)
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT

  # Allow returning packets
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow local traffic
  iptables -A INPUT -i lo -j ACCEPT

  # allow ssh connections from anywhere
  iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  # allow http connections from anywhere
  iptables -A INPUT -p udp --dport 1194 -j ACCEPT

  # allow icmp packets
  iptables -A INPUT -p icmp -j ACCEPT

  # masquerade forwarded packets
  iptables -t nat -A POSTROUTING -j MASQUERADE
END

cat <<END
  touch /run/iptables
fi
END
}

firewall_upstart_conf() {
  cat <<'END'
description "Nanobox firewall base lockdown"

start on runlevel [2345]

emits firewall

script

/usr/local/bin/build-firewall.sh
initctl emit firewall

end script
END
}

firewall_systemd_conf() {
  cat <<'END'
[Unit]
Description=Nanobox firewall base lockdown

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/build-firewall.sh

[Install]
WantedBy=multi-user.target
END
}

configure_firewall() {
  # create init script
  if [[ "$(init_system)" = "systemd" ]]; then
    echo "$(firewall_systemd_conf)" > /etc/systemd/system/firewall.service
    systemctl enable firewall.service
  elif [[ "$(init_system)" = "upstart" ]]; then
    echo "$(firewall_upstart_conf)" > /etc/init/firewall.conf
  fi

  # create firewall script
  echo "$(build_firewall)" > /usr/local/bin/build-firewall.sh

  # update permissions
  chmod 755 /usr/local/bin/build-firewall.sh
}

start_firewall() {
  # ensure the firewall service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service firewall status | grep "active (running)"` ]]; then
      service firewall start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service firewall status | grep start/running` ]]; then
      service firewall start
    fi
  fi
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
  prompt_user KEY_NAME "Enter the name (e.g vpn.unity.nanobox.io): "
  prompt_user KEY_ALTNAMES "Enter the alt name (e.g vpn): "
  prompt_user KEY_OU "Enter the organizational unit (e.g web): "
  prompt_user VPN_SUBNET "Enter the subnet to use for the VPN service (e.g 10.0.100.0): "
  prompt_user VPN_NETMASK "Enter the netmask to use for the VPN service (e.g 255.255.255.0): "
  prompt_user VPC_SUBNET "Enter the subnet for the VPC (e.g 10.0.0.0): "
  prompt_user VPC_NETMASK "Enter the subnet for the VPC (e.g 255.255.0.0): "
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

# Extra data for Nanobox
export VPN_SUBNET=${VPN_SUBNET}
export VPN_NETMASK=${VPN_NETMASK}
export VPC_SUBNET=${VPC_SUBNET}
export VPC_NETMASK=${VPC_NETMASK}
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

openvpn_server_conf() {
  cat <<'END'
#################################################
# Sample OpenVPN 2.0 config file for            #
# multi-client server.                          #
#                                               #
# This file is for the server side              #
# of a many-clients <-> one-server              #
# OpenVPN configuration.                        #
#                                               #
# OpenVPN also supports                         #
# single-machine <-> single-machine             #
# configurations (See the Examples page         #
# on the web site for more info).               #
#                                               #
# This config should work on Windows            #
# or Linux/BSD systems.  Remember on            #
# Windows to quote pathnames and use            #
# double backslashes, e.g.:                     #
# "C:\\Program Files\\OpenVPN\\config\\foo.key" #
#                                               #
# Comments are preceded with '#' or ';'         #
#################################################

# Which local IP address should OpenVPN
# listen on? (optional)
;local a.b.c.d

# Which TCP/UDP port should OpenVPN listen on?
# If you want to run multiple OpenVPN instances
# on the same machine, use a different port
# number for each one.  You will need to
# open up this port on your firewall.
port 1194

# TCP or UDP server?
;proto tcp
proto udp

# "dev tun" will create a routed IP tunnel,
# "dev tap" will create an ethernet tunnel.
# Use "dev tap0" if you are ethernet bridging
# and have precreated a tap0 virtual interface
# and bridged it with your ethernet interface.
# If you want to control access policies
# over the VPN, you must create firewall
# rules for the the TUN/TAP interface.
# On non-Windows systems, you can give
# an explicit unit number, such as tun0.
# On Windows, use "dev-node" for this.
# On most systems, the VPN will not function
# unless you partially or fully disable
# the firewall for the TUN/TAP interface.
;dev tap
dev tun

# Windows needs the TAP-Win32 adapter name
# from the Network Connections panel if you
# have more than one.  On XP SP2 or higher,
# you may need to selectively disable the
# Windows firewall for the TAP adapter.
# Non-Windows systems usually don't need this.
;dev-node MyTap

# SSL/TLS root certificate (ca), certificate
# (cert), and private key (key).  Each client
# and the server must have their own cert and
# key file.  The server and all clients will
# use the same ca file.
#
# See the "easy-rsa" directory for a series
# of scripts for generating RSA certificates
# and private keys.  Remember to use
# a unique Common Name for the server
# and each of the client certificates.
#
# Any X509 key management system can be used.
# OpenVPN can also use a PKCS #12 formatted key file
# (see "pkcs12" directive in man page).
ca /etc/openvpn/easy-rsa/keys/ca.crt
END
  cat <<END
cert /etc/openvpn/easy-rsa/keys/${KEY_NAME}.crt
key /etc/openvpn/easy-rsa/keys/${KEY_NAME}.key  # This file should be kept secret
END
  cat <<'END'
# Diffie hellman parameters.
# Generate your own with:
#   openssl dhparam -out dh2048.pem 2048
dh /etc/openvpn/easy-rsa/keys/dh2048.pem

# Network topology
# Should be subnet (addressing via IP)
# unless Windows clients v2.0.9 and lower have to
# be supported (then net30, i.e. a /30 per client)
# Defaults to net30 (not recommended)
;topology subnet

# Configure server mode and supply a VPN subnet
# for OpenVPN to draw client addresses from.
# The server will take 10.8.0.1 for itself,
# the rest will be made available to clients.
# Each client will be able to reach the server
# on 10.8.0.1. Comment this line out if you are
# ethernet bridging. See the man page for more info.
END
  cat <<END
server ${VPN_SUBNET} ${VPN_NETMASK}
END
  cat <<'END'

# Maintain a record of client <-> virtual IP address
# associations in this file.  If OpenVPN goes down or
# is restarted, reconnecting clients can be assigned
# the same virtual IP address from the pool that was
# previously assigned.
ifconfig-pool-persist ipp.txt

# Configure server mode for ethernet bridging.
# You must first use your OS's bridging capability
# to bridge the TAP interface with the ethernet
# NIC interface.  Then you must manually set the
# IP/netmask on the bridge interface, here we
# assume 10.8.0.4/255.255.255.0.  Finally we
# must set aside an IP range in this subnet
# (start=10.8.0.50 end=10.8.0.100) to allocate
# to connecting clients.  Leave this line commented
# out unless you are ethernet bridging.
;server-bridge 10.8.0.4 255.255.255.0 10.8.0.50 10.8.0.100

# Configure server mode for ethernet bridging
# using a DHCP-proxy, where clients talk
# to the OpenVPN server-side DHCP server
# to receive their IP address allocation
# and DNS server addresses.  You must first use
# your OS's bridging capability to bridge the TAP
# interface with the ethernet NIC interface.
# Note: this mode only works on clients (such as
# Windows), where the client-side TAP adapter is
# bound to a DHCP client.
;server-bridge

# Push routes to the client to allow it
# to reach other private subnets behind
# the server.  Remember that these
# private subnets will also need
# to know to route the OpenVPN client
# address pool (10.8.0.0/255.255.255.0)
# back to the OpenVPN server.
;push "route 192.168.10.0 255.255.255.0"
;push "route 192.168.20.0 255.255.255.0"
END
  cat <<END
push "route ${VPC_SUBNET} ${VPC_NETMASK}"
END
  cat <<'END'

# To assign specific IP addresses to specific
# clients or if a connecting client has a private
# subnet behind it that should also have VPN access,
# use the subdirectory "ccd" for client-specific
# configuration files (see man page for more info).

# EXAMPLE: Suppose the client
# having the certificate common name "Thelonious"
# also has a small subnet behind his connecting
# machine, such as 192.168.40.128/255.255.255.248.
# First, uncomment out these lines:
;client-config-dir ccd
;route 192.168.40.128 255.255.255.248
# Then create a file ccd/Thelonious with this line:
#   iroute 192.168.40.128 255.255.255.248
# This will allow Thelonious' private subnet to
# access the VPN.  This example will only work
# if you are routing, not bridging, i.e. you are
# using "dev tun" and "server" directives.

# EXAMPLE: Suppose you want to give
# Thelonious a fixed VPN IP address of 10.9.0.1.
# First uncomment out these lines:
;client-config-dir ccd
;route 10.9.0.0 255.255.255.252
# Then add this line to ccd/Thelonious:
#   ifconfig-push 10.9.0.1 10.9.0.2

# Suppose that you want to enable different
# firewall access policies for different groups
# of clients.  There are two methods:
# (1) Run multiple OpenVPN daemons, one for each
#     group, and firewall the TUN/TAP interface
#     for each group/daemon appropriately.
# (2) (Advanced) Create a script to dynamically
#     modify the firewall in response to access
#     from different clients.  See man
#     page for more info on learn-address script.
learn-address /usr/bin/vpn-learn-address

# If enabled, this directive will configure
# all clients to redirect their default
# network gateway through the VPN, causing
# all IP traffic such as web browsing and
# and DNS lookups to go through the VPN
# (The OpenVPN server machine may need to NAT
# or bridge the TUN/TAP interface to the internet
# in order for this to work properly).
;push "redirect-gateway def1 bypass-dhcp"

# Certain Windows-specific network settings
# can be pushed to clients, such as DNS
# or WINS server addresses.  CAVEAT:
# http://openvpn.net/faq.html#dhcpcaveats
# The addresses below refer to the public
# DNS servers provided by opendns.com.
;push "dhcp-option DNS 208.67.222.222"
;push "dhcp-option DNS 208.67.220.220"

# Uncomment this directive to allow different
# clients to be able to "see" each other.
# By default, clients will only see the server.
# To force clients to only see the server, you
# will also need to appropriately firewall the
# server's TUN/TAP interface.
;client-to-client

# Uncomment this directive if multiple clients
# might connect with the same certificate/key
# files or common names.  This is recommended
# only for testing purposes.  For production use,
# each client should have its own certificate/key
# pair.
#
# IF YOU HAVE NOT GENERATED INDIVIDUAL
# CERTIFICATE/KEY PAIRS FOR EACH CLIENT,
# EACH HAVING ITS OWN UNIQUE "COMMON NAME",
# UNCOMMENT THIS LINE OUT.
;duplicate-cn

# The keepalive directive causes ping-like
# messages to be sent back and forth over
# the link so that each side knows when
# the other side has gone down.
# Ping every 10 seconds, assume that remote
# peer is down if no ping received during
# a 120 second time period.
keepalive 10 120

# For extra security beyond that provided
# by SSL/TLS, create an "HMAC firewall"
# to help block DoS attacks and UDP port flooding.
#
# Generate with:
#   openvpn --genkey --secret ta.key
#
# The server and each client must have
# a copy of this key.
# The second parameter should be '0'
# on the server and '1' on the clients.
;tls-auth ta.key 0 # This file is secret

# Select a cryptographic cipher.
# This config item must be copied to
# the client config file as well.
# Note that v2.4 client/server will automatically
# negotiate AES-256-GCM in TLS mode.
# See also the ncp-cipher option in the manpage
cipher AES-256-CBC

# Enable compression on the VPN link and push the
# option to the client (v2.4+ only, for earlier
# versions see below)
;compress lz4-v2
;push "compress lz4-v2"

# For compression compatible with older clients use comp-lzo
# If you enable it here, you must also
# enable it in the client config file.
;comp-lzo

# The maximum number of concurrently connected
# clients we want to allow.
;max-clients 100

# It's a good idea to reduce the OpenVPN
# daemon's privileges after initialization.
#
# You can uncomment this out on
# non-Windows systems.
;user nobody
;group nobody

# The persist options will try to avoid
# accessing certain resources on restart
# that may no longer be accessible because
# of the privilege downgrade.
persist-key
persist-tun

# Output a short status file showing
# current connections, truncated
# and rewritten every minute.
status openvpn-status.log

# By default, log messages will go to the syslog (or
# on Windows, if running as a service, they will go to
# the "\Program Files\OpenVPN\log" directory).
# Use log or log-append to override this default.
# "log" will truncate the log file on OpenVPN startup,
# while "log-append" will append to it.  Use one
# or the other (but not both).
;log         openvpn.log
;log-append  openvpn.log

# Set the appropriate level of log
# file verbosity.
#
# 0 is silent, except for fatal errors
# 4 is reasonable for general usage
# 5 and 6 can help to debug connection problems
# 9 is extremely verbose
verb 3

# Silence repeating messages.  At most 20
# sequential messages of the same message
# category will be output to the log.
;mute 20

# Notify the client that when the server restarts so it
# can automatically reconnect.
;explicit-exit-notify 1
END
}

download_openvpn_scripts() {
  # download file
  echo "Downloading ovpn script"
  curl -s https://s3.amazonaws.com/unity.nanobox.io/bootstrap/vpn/unity-ovpn.tar.gz > ${TMPFILE}
}

download_openvpn_scripts_checksum() {
  # download checksum
  curl -s https://s3.amazonaws.com/unity.nanobox.io/bootstrap/vpn/unity-ovpn.md5
}

checksum_openvpn_scripts() {
  # checksum file
  cat $TMPFILE | md5sum | awk '{print $1}'
}

install_openvpn_scripts() {
  # move into place if checksums match
  download_openvpn_scripts
  echo "Verifying checksums"
  if [ "$(download_openvpn_scripts_checksum)" = "$(checksum_openvpn_scripts)" ]; then
    tar -xvzf ${TMPFILE} --no-overwrite-dir -C /
  else
    echo "Error: Checksums didn't match"
  fi
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

configure_openvpn() {
  echo "$(openvpn_server_conf)" > /etc/openvpn/server.conf
  install_openvpn_scripts
  systemctl enable openvpn@server
  systemctl start openvpn@server
}

apt_update_upgrade
install_packages
configure_firewall
configure_sysctl
configure_easy_rsa
configure_openvpn

