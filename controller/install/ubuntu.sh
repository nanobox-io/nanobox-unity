#!/bin/bash
#
# Boostraps an ubuntu machine to be used as an agent for nanobox

# exit if any any command fails
set -e

set -o pipefail

# todo:
# set timezone

wait_for_lock() {
  # wait to make sure no package updates are currently running, it'll break the bootstrap script if it is running.
  while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 ; do
    sleep 1
  done
}

init_system() {
  if [[ -f /sbin/systemctl || -f /bin/systemctl ]]; then
    echo "systemd"
  elif [[ -f /sbin/initctl || -f /bin/initctl ]]; then
    echo "upstart"
  else
    echo "sysvinit"
  fi
}

# install docker and docker compose
install_docker() {

  # update the package index
  echo '   -> apt-get update'
  time ( wait_for_lock; apt-get -y update )

  # ensure lsb-release is installed
  which lsb_release || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install lsb-release )
  which curl || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install curl )
  which add-apt-repository || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install software-properties-common )
  which gpg || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install gnupg )
  which rngd || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install rng-tools )
  [ -f /usr/lib/apt/methods/https ] || ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y install apt-transport-https )
  # systemd-resolved interferes with running unity
  if [ -f /etc/systemd/system/multi-user.target.wants/systemd-resolved.service ]; then
    systemctl disable systemd-resolved
    systemctl stop systemd-resolved
    systemctl mask systemd-resolved
    rm /etc/resolv.conf
    ln -s /run/resolvconf/resolv.conf /etc/resolv.conf
    cat > /etc/resolvconf/resolv.conf.d/base <<'END'
nameserver 1.1.1.1
nameserver 8.8.8.8
END
    resolvconf -u
  fi

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  time ( wait_for_lock; apt-get -y update )

  # ensure the old repo is purged
  echo '   -> remove old docker'
  time ( wait_for_lock; dpkg --purge lxc-docker docker-engine )

  # install aufs kernel module
  if [ ! -f /lib/modules/$(uname -r)/kernel/fs/aufs/aufs.ko ]; then
    # make parent directory
    [ -d /lib/modules/$(uname -r)/kernel/fs/aufs ] || mkdir -p /lib/modules/$(uname -r)/kernel/fs/aufs

    # get aufs kernel module
    time ( wait_for_lock; sudo apt-get install -y linux-image-extra-$(uname -r) linux-image-extra-virtual )
  fi

  # enable use of aufs
  echo '   -> install aufs'
  modprobe aufs || ( time depmod && time modprobe aufs )

  # set docker options
  cat > /etc/default/docker <<'END'
DOCKER_OPTS="--storage-driver=aufs"
END

  if [[ "$(init_system)" = "systemd" ]]; then
    # use docker options
    [ -d /lib/systemd/system/docker.service.d ] || mkdir /lib/systemd/system/docker.service.d
    cat > /lib/systemd/system/docker.service.d/env.conf <<'END'
[Service]
EnvironmentFile=/etc/default/docker
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// $DOCKER_OPTS
END
  fi

  # install docker
  echo '   -> install docker'
  time ( wait_for_lock; apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y docker-ce )
  curl -L https://github.com/docker/compose/releases/download/1.22.0/docker-compose-$(uname -s)-$(uname -m) -o /usr/bin/docker-compose
  chmod 755 /usr/bin/docker-compose
}

start_docker() {
  # ensure the docker service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service docker status | grep "active (running)"` ]]; then
      service docker start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service docker status | grep start/running` ]]; then
      service docker start
    fi
  fi

  # wait for the docker sock file
  while [ ! -S /var/run/docker.sock ]; do
    sleep 1
  done
}

configure_modloader() {
  if [[ "$(init_system)" = "systemd" ]]; then
    echo 'ip_vs' > /etc/modules-load.d/nanobox-ipvs.conf
  elif [[ "$(init_system)" = "upstart" ]]; then
    grep 'ip_vs' /tmpetc/modules &> /dev/null || echo 'ip_vs' >> /etc/modules
  fi
}

start_modloader() {
  modprobe ip_vs
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

# conifgure automatic updates to not update kernel or docker
configure_updates() {
  # Remove extra architectures (will exit 0 but display warning if none)
  # Linode servers have i386 added for convenience(?) but we want fast
  # apt updates.
  wait_for_lock
  dpkg --remove-architecture "$(dpkg --print-foreign-architectures)"

  # trim extra sources for faster apt updates
  sed -i -r '/(-src|backports)/d' /etc/apt/sources.list

  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'END'
// Automatically upgrade packages from these (origin:archive) pairs
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};

// List of packages to not update (regexp are supported)
Unattended-Upgrade::Package-Blacklist {
    "docker-engine";
    "linux-image-*";
    "linux-headers-*";
    "linux-virtual";
//  "linux-image-extra-virtual";
//  "linux-image-virtual";
//  "linux-headers-generic";
//  "linux-headers-virtual";
};
END

# disable auto-updates alltogether
  cat > /etc/apt/apt.conf.d/10periodic <<'END'
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
END
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
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT

  # allow https connections from anywhere
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT

  # allow dns connections from anywhere
  iptables -A INPUT -p udp --dport 53 -j ACCEPT

  # allow icmp packets
  iptables -A INPUT -p icmp -j ACCEPT

  # Allow vxlan and docker traffic
  iptables -A INPUT -i docker0 -j ACCEPT
  iptables -A FORWARD -i docker0 -j ACCEPT
  iptables -A FORWARD -o docker0 -j ACCEPT
  iptables -t nat -A POSTROUTING -o ${INTERNAL_IFACE} -j MASQUERADE
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

prompt_user() {
  variable=$1
  while [ -z ${!variable} ]; do
    read -p "Provide value for ${variable}: " ${variable}
  done
}

add_provider_credentials() {
  local BACK=false

  while [ $BACK = 'false' ]; do
    cat <<END
Provider configuration Options:
aws: Configure AWS - EC2_KEY_ID and EC2_ACCESS_KEY
back: Return to configuring server
END
    read -p "Which option [aws|back]: " option
    case $option in
      aws)
        for i in EC2_KEY_ID EC2_ACCESS_KEY; do
          prompt_user $i
        done
        ;;
      back)
        BACK=true
        ;;
      default)
        ;;
    esac
  done
}


ensure_variables_have_values() {
  for i in DEFAULT_USER DEFAULT_PASSWORD DOMAIN APP_DOMAIN UNITY_LICENSE; do
    if [ -z ${!i} ]; then
      prompt_user $i
    fi
  done
}

generate_cryptograpic_keys() {
  echo "Generating cryptograpic keys"
  SECRET_KEY_BASE=$(docker run --rm nanobox/unity-core nanobox keygen | grep KEY | awk '{print $2}')
  SHAMAN_TOKEN=$(docker run --rm nanobox/unity-core nanobox keygen | grep KEY | awk '{print $2}')
  PROXY_TOKEN=$(docker run --rm nanobox/unity-core nanobox keygen | grep KEY | awk '{print $2}')
}

create_unity_env_file() {
  cat <<END
COMPOSE_PROJECT_NAME=unity
DATA_QUEUE_HOST=queue
DATA_REDIS_HOST=queue
DATA_DB_HOST=db
DATA_DB_USER=postgres
DOMAIN=${DOMAIN}
APP_DOMAIN=${APP_DOMAIN}
ODIN_MANDRILL_API_KEY=
SECRET_KEY_BASE=${SECRET_KEY_BASE}
UNITY_LICENSE=${UNITY_LICENSE}
SHAMAN_HOST=dns
SHAMAN_TOKEN=${SHAMAN_TOKEN}
PROXY_HOST=proxy
PROXY_TOKEN=${PROXY_TOKEN}
ADAPTER_URL=http://adapter:8080
DEFAULT_USER=${DEFAULT_USER}
DEFAULT_PASSWORD=${DEFAULT_PASSWORD}
END
  if [ -n $EC2_KEY_ID ]; then
    echo "EC2_KEY_ID=$EC2_KEY_ID"
  fi
  if [ -n $EC2_ACCESS_KEY ]; then
    echo "EC2_ACCESS_KEY=$EC2_ACCESS_KEY"
  fi
}

unity_yml() {
  cat <<'END'
version: '3.1'

services:
  # the postgres database
  db:
    image: 'postgres:10.3-alpine'
    volumes:
      - 'db_data:/var/lib/postgresql/data'
    env_file:
      - '/etc/nanobox/.env'
      
  # the sidekiq worker queue
  queue:
    image: 'redis:4.0-alpine'
    volumes:
      - 'queue_data:/data'
    env_file:
      - '/etc/nanobox/.env'
  
  # libcloud adapters
  adapter:
    image: 'nanobox/unity-adapter'
    command: gunicorn -c /app/etc/gunicorn.py nanobox_libcloud:app
    env_file:
      - '/etc/nanobox/.env'
      
  # shaman convenience dns for hosted apps
  dns:
    image: 'nanobox/unity-dns'
    volumes:
      - 'dns_data:/var/db/shaman'
    command: shaman -c /etc/shaman/config.json -t $SHAMAN_TOKEN
    ports:
      - "53:8053/udp"
    expose:
      - "1632"
    env_file:
      - '/etc/nanobox/.env'
      
  # nginx proxy for this app
  router:
    image: jwilder/nginx-proxy:alpine
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
  
  # unity web service
  web:
    image: 'nanobox/unity-core'
    command: nanobox server
    expose:
      - "8080"
    depends_on:
      - db
      - queue
      - adapter
      - dns
      - proxy
    env_file:
      - '/etc/nanobox/.env'
    environment:
      VIRTUAL_HOST: "dashboard.${DOMAIN},api.${DOMAIN}"
    
  # unity workers
  worker:
    image: 'nanobox/unity-core'
    command: nanobox worker
    depends_on:
      - db
      - queue
      - adapter
      - dns
      - proxy
    env_file:
      - '/etc/nanobox/.env'
      
  # the dashboard proxy to end-run browser security issues
  proxy:
    image: 'nanobox/unity-proxy'
    volumes:
      - 'proxy_data:/var/db/portal'
    command: portal -c /etc/portal/config.json -t $PROXY_TOKEN
    ports:
      - "8444:8444"
    env_file:
      - '/etc/nanobox/.env'
    environment:
      VIRTUAL_HOST: "proxy.${DOMAIN}"
    
volumes:
  db_data:
  queue_data:
  dns_data:
  proxy_data:

END
}

configure_unity() {
  [ -d /etc/nanobox ] || mkdir /etc/nanobox
  echo "$(create_unity_env_file)" > /etc/nanobox/.env
  echo "$(unity_yml)" > /etc/nanobox/unity.yml
  # create init script
  if [[ "$(init_system)" = "systemd" ]]; then
    echo "$(unity_systemd_conf)" > /etc/systemd/system/unity.service
    systemctl enable unity.service
  elif [[ "$(init_system)" = "upstart" ]]; then
    echo "$(unity_upstart_conf)" > /etc/init/unity.conf
  fi
}

setup_database() {
  (cd /etc/nanobox; docker-compose -f /etc/nanobox/unity.yml run web nanobox migrate)
}

start_unity() {
  # ensure the docker-compose service is started
  if [[ "$(init_system)" = "systemd" ]]; then
    if [[ ! `service unity status | grep "active (running)"` ]]; then
      service unity start
    fi
  elif [[ "$(init_system)" = "upstart" ]]; then
    if [[ ! `service unity status | grep start/running` ]]; then
      service unity start
    fi
  fi
}

unity_upstart_conf() {
  cat <<'END'
description "Nanobox Unity"

start on runlevel [2345]

script

chdir /etc/nanobox/
docker-compose -f /etc/nanobox/unity.yml up

end script
END
}

unity_systemd_conf() {
  cat <<'END'
[Unit]
Description=Nanobox Unity

[Service]
EnvironmentFile=/etc/nanobox/.env
WorkingDirectory=/etc/nanobox
ExecStart=/usr/bin/docker-compose -f /etc/nanobox/unity.yml up
ExecStop=/usr/bin/docker-compose -f /etc/nanobox/unity.yml down

[Install]
WantedBy=multi-user.target
END
}

run() {
  echo "+> $2"
  $1 2>&1 | format '   '
}

format() {
  prefix=$1
  while read -s LINE;
  do
    echo "${prefix}${LINE}"
  done
}

for i in "${@}"; do

  case $i in
    default-user=* )
      DEFAULT_USER=${i#*=}
      ;;
    default-password=* )
      DEFAULT_PASSWORD=${i#*=}
      ;;
    unity-license=* )
      UNITY_LICENSE=${i#*=}
      ;;
    domain=* )
      DOMAIN=${i#*=}
      ;;
    app-domain=* )
      APP_DOMAIN=${i#*=}
      ;;
  esac

done

# silently fix hostname in ps1

ensure_variables_have_values
add_provider_credentials

run configure_updates "Configuring automatic updates"

run install_docker "Installing docker"
run start_docker "Starting docker daemon"

run configure_modloader "Configuring modloader"
run start_modloader "Starting modloader"

#run configure_firewall "Configuring firewall"
#run start_firewall "Starting firewall"

generate_cryptograpic_keys
run setup_database "Setting up Nanobox Database"
run configure_unity "Configuring Nanobox Unity"
run start_unity "Starting Nanobox Unity"

#run create_nanobox_environment "Creating environment for nanobox"
#run docker_compose_nanobox "Starting nanobox services"

echo "+> Nanobox now starting..."