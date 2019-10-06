#!/bin/bash

################################################################
#
# This script attempts remove everything that the other ootb scripts installed
# There is no guarantee that it will remove everything, nor that it wont
# remove something it shouldn't. It is used for testing

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

BEATS_LIST="metricbeat auditbeat packetbeat filebeat heartbeat-elastic"

WEBGOAT_DC_FILE=webgoat-doc-comp.yml

remove_on_Debian() {

  sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge $BEATS_LIST \
    docker-ce docker-ce-cli containerd.io docker-compose apache2 maven
    
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove

  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo apt-key del -
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key del -
  
  sudo rm -f \
    /etc/apt/sources.list.d/docker-ce.list \
    /etc/apt/sources.list.d/elastic-7.x.list
    
  sudo rm -rf /etc/apache2

}

remove_on_Ubuntu() { remove_on_Debian ; }

remove_on_CentOS() {

  sudo yum remove -y $BEATS_LIST \
    docker-ce docker-ce-cli containerd.io httpd maven
  
  sudo yum autoremove -y

  sudo rm -f /etc/yum.repos.d/elastic.repo \
    /etc/yum.repos.d/docker-ce.repo \
    /usr/local/bin/docker-compose
  
  sudo rm -rf /etc/httpd

}



remove_on_RHEL() { remove_on_CentOS ; }

########################################################
# Script

if [ -x $(which docker-compose) -a -f "$WEBGOAT_DC_FILE" ]; then
  docker-compose -f "$WEBGOAT_DC_FILE" rm -fsv || true
fi

test -n "$HOME" && rm -rf "$HOME/.m2"
test -f "$WEBGOAT_DC_FILE" && rm -f "$WEBGOAT_DC_FILE"

# Beats packages don't stop their services when removed..
for beat in $BEATS_LIST; do
  sudo systemctl stop $beat || true
  sudo systemctl disable $beat || true
done

remove_on_$(lsb_release -is)

for beat in $BEATS_LIST; do
  BEAT=${beat%-elastic}
  test -n "$BEAT" && sudo rm -rf /etc/$BEAT
done

if [ -f "es-ootb.conf" ]; then
  BAK="es-ootb.conf-$(date +%F)"
  # Don't overwrite the backup copy, just clear the old conf
  if [ -f $BAK ]; then
    echo -n >"es-ootb.conf"
  else
    mv "es-ootb.conf" "$BAK"
  fi
fi
