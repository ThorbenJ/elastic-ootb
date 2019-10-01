#!/bin/bash

# Print the commands this script is executing
set -x

# List of beats to install and configure
BEATS2INSTALL="metricbeat auditbeat packetbeat filebeat heartbeat-elastic"

# Helper print message and exit
_fail() {
  echo $@
  exit 1
}

# Read config variables
test -f es-ootb.conf || _fail "Config file es-ootb.conf missing"
. es-ootb.conf

#############################################################
# Functions
#

# Check config variables are set
cheack_config() {
  test -n "$ES_CLOUD_ID" || _fail "ES_CLOUD_ID missing from es-ootb.conf"
  test -n "$ES_CLOUD_AUTH" || _fail "ES_CLOUD_AUTH missing from es-ootb.conf"
}

# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
install_on_Debian() {
  sudo apt-get install apt-transport-https curl
  curl https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
  echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list >/dev/null
  sudo apt-get update

  sudo apt-get install $BEATS2INSTALL
}

# Same as debian
install_on_Ubuntu() { install_on_Debian; }

# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
# Not tested
install_on_Centos() {
  sudo rpm --import https://packages.elastic.co/GPG-KEY-elasticsearch
  cat <<_EOF_ |
[elastic-7.x]
name=Elastic repository for 7.x packages
baseurl=https://artifacts.elastic.co/packages/7.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
_EOF_
  sudo tee /etc/yum.repos.d/elastic.repo

  #sudo yum repolist

  sudo yum install $BEATS2INSTALL
}

install_on_RHEL() { install_on_Centos; }

# Configuration for most beats
configure_common() {
  BEAT_CONF="/etc/$1/$1.yml"
  test -f "$BEAT_CONF" || _fail "Beat config file missing: $BEAT_CONF"

  # Keep a copy of the original, if not already done
  test -f "${BEAT_CONF}.original" || sudo cp "$BEAT_CONF" "${BEAT_CONF}.original"

  # This script always starts with a clean "original" copy of the config
  # This avoids multiple executions from appending the same thing multiple times
  sudo cp "${BEAT_CONF}.original" "${BEAT_CONF}"

  # Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/configure-cloud-id.html (same for all beats)
  # Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/monitoring-internal-collection.html
  cat <<_EOF_ |

## OOTB script appended all below here ##

cloud.id: "$ES_CLOUD_ID"
cloud.auth: "$ES_CLOUD_AUTH"

monitoring:
  enabled: true

_EOF_
  sudo tee -a "$BEAT_CONF" >/dev/null
}

configure_auditbeat() {
  configure_common auditbeat
}

configure_filebeat() {
  configure_common filebeat

  # Repeated yaml entries completly overwrite/replace previous entries; so filebeat.inputs here overrides any previous configuration
  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-container.html
  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/add-docker-metadata.html
  cat <<_EOF_ |
filebeat.inputs:
- type: container
  paths:
    - '/var/lib/docker/containers/*/*.log'
#  json.keys_under_root: true
#  json.add_error_key: true
#  json.message_key: log

processors:
  - add_docker_metadata: ~
  - add_host_metadata: ~
  - add_cloud_metadata: ~

_EOF_
  sudo tee -a /etc/filebeat/filebeat.yml >/dev/null

  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-modules.html
  sudo filebeat modules enable system 
}

configure_heartbeat() {
  configure_common heartbeat

  # Doc Ref: https://www.elastic.co/guide/en/beats/heartbeat/current/configuration-autodiscover.html
  # single quote ' _EOF_ to disable shell substituion, otherwise bash will complain about ${data.host}, etc.
  cat <<'_EOF_' |
# Disable previously configured monitors
heartbeat.monitors: ~

heartbeat.autodiscover:
  providers:
    - type: docker
      templates:
        - config:
          - type: tcp
            id: "${data.docker.container.id}-${data.port}"
            name: "${data.docker.container.name}_${data.port}"
            fields.docker_info: ${data.docker}
            hosts: ["${data.host}:${data.port}"]
            schedule: "@every 10s"
            timeout: 1s

processors:
- add_observer_metadata: ~
- add_docker_metadata: ~

_EOF_
  sudo tee -a /etc/heartbeat/heartbeat.yml >/dev/null

}

configure_metricbeat() {
  configure_common metricbeat

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/metricbeat-modules.html
  sudo metricbeat modules enable system beat docker
}

configure_packetbeat() {
  configure_common packetbeat
}

launch_via_systemd() {
  sudo systemctl enable $1
  sudo systemctl restart $1
}

##########################################################################
# Script starts here
#

check_config
install_on_$(lsb_release -is)

for beat in $BEATS2INSTALL; do
  BEAT=${beat%-elastic}

  configure_$BEAT

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/command-line-options.html#setup-command
  test -n "$ES_BEAT_SKIP_SETUP" || sudo $BEAT setup

  launch_via_systemd $beat
done

