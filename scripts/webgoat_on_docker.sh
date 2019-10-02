#!/bin/bash

#################################################################
#
# This script will install docker and then run WebGoat on docker.
# Please run this as a normal user that can execute sudo
# This script:-
# - is annoted to reference to documentation
# - requires: sudo, curl, lsb_release
# - can run on: Debian, Ubuntu (etc.), Centos, RHEL (etc.)
# - will pass its argument to docker-compose (See end)
#   e.g. run: webgoat_on_docker up
#

# Avoid issues with locales
unset LANG LC_CTYPE LC_ALL

# Print the commands this script is executing
set -x

# Stop script if any command returns an error
set -e

# Helper print message and exit
_fail() {
  echo $@ >&2
  exit 1
}

# Test that programmes we are going to use are installed
for c in curl sudo lsb_release; do
  test -x "$(which $c)" || _fail "Programme '$c' appears to be missing"
done

WEBGOAT_DC_FILE=webgoat-doc-comp.yml

# Read config variables
test -f es-ootb.conf || _fail "Config file es-ootb.conf missing"
. es-ootb.conf

###############################################################
# Functions
#

##### Installation ######

# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
install_on_Debian() {

  if ! test -f /etc/apt/sources.list.d/docker-ce.list; then
    # Doc Ref: https://docs.docker.com/install/linux/docker-ce/debian/
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install apt-transport-https ca-certificates
  
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key add -
  
    echo "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker-ce.list >/dev/null

    sudo apt-get update
  fi
  
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
    docker-ce docker-ce-cli containerd.io docker-compose
  
} # End: install_on_Debian

# Same as debian
# Not tested
install_on_Ubuntu() { install_on_Debian; }


# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
install_on_CentOS() {

  # Doc Ref: https://docs.docker.com/install/linux/docker-ce/centos/
  sudo yum install -y yum-utils device-mapper-persistent-data lvm2
  sudo yum-config-manager --add-repo \
    "https://download.docker.com/linux/centos/docker-ce.repo"

  sudo yum install -y docker-ce docker-ce-cli containerd.io
  
  # Doc Ref: https://docs.docker.com/compose/install/
  if ! test -f /usr/local/bin/docker-compose ; then
    sudo curl -L "https://github.com/docker/compose/releases/download/1.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  fi
  
} # End: install_on_CentOS

# Not tested
install_on_RHEL() { install_on_CentOS; }

configure_user(){

  if ! groups|grep -q docker ; then
    echo Adding $USER to docker group
    sudo usermod -aG docker $USER
    
    echo "YOU MUST LOGOUT AND BACK IN!"
    echo "So that your user has its new docker group membership"
    
    exit 2
    
  fi
}

launch_via_systemd() {
  sudo systemctl enable $1
  sudo systemctl start $1
}

################################################################
# Script
#

# e.g. install_on_Debian or install_on_CentOS
install_on_$(lsb_release -is)

configure_user

launch_via_systemd docker

# Doc Ref: https://github.com/WebGoat/WebGoat
test -f "$WEBGOAT_DC_FILE" || \
 curl https://raw.githubusercontent.com/WebGoat/WebGoat/develop/docker-compose.yml -o "$WEBGOAT_DC_FILE"

docker-compose -f "$WEBGOAT_DC_FILE" $@
