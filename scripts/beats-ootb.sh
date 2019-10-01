#!/bin/bash

# Print the commands this script is executing
set -x

# Stop script if any command returns an error
set -e

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

# Check config variables are set
test -n "$ES_CLOUD_ID" || _fail "ES_CLOUD_ID missing from es-ootb.conf"
test -n "$ES_CLOUD_AUTH" || _fail "ES_CLOUD_AUTH missing from es-ootb.conf"

ES_CLOUD_INFO=$(echo ${ES_CLOUD_ID#*:} | base64 -d -)
ES_DOMAIN=$(echo $ES_CLOUD_INFO | cut -d $ -f1)
ES_ELASRCH_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f2)
ES_KIBANA_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f3)

#############################################################
# Functions
#

# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
install_on_Debian() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install apt-transport-https curl
  curl https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
  echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list >/dev/null
  sudo apt-get update

  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install $BEATS2INSTALL
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

  cat <<_EOF_ |

## OOTB script appended all below here ##

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/configure-cloud-id.html (same for all beats)
cloud.id: "$ES_CLOUD_ID"
cloud.auth: "$ES_CLOUD_AUTH"

# Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/elasticsearch-output.html#pipeline-option-es
output.elasticsearch.pipeline: "${1}-in"

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/monitoring-internal-collection.html
monitoring:
  enabled: true

_EOF_
  sudo tee -a "$BEAT_CONF" >/dev/null
}

configure_auditbeat() {
  configure_common auditbeat

  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/auditbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Auditbeat ingest pipeline",
  "processors": [
    {
      "pipeline": {
        "name": "geoip-info"
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply
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

  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/filebeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Filebeat ingest pipeline",
  "processors": [
    {
      "pipeline": {
        "name": "geoip-info"
      }
    },
    {
      "pipeline": {
        "if": "0 == 1",
        "name": "filebeat-{{_ingest.agent.version}}-iptables-log-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.fileset.name == 'auth'",
        "name": "filebeat-{{_ingest.agent.version}}-system-auth-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.fileset.name == 'syslog'",
        "name": "filebeat-{{_ingest.agent.version}}-system-syslog-pipeline"
      }
    }
  ]
}
_EOF_

  echo #add a new line after the REST reply
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

  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/heartbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Heartbeat ingest pipeline",
  "processors": [
    {
      "pipeline": {
        "name": "geoip-info"
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply
}

configure_metricbeat() {
  configure_common metricbeat

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/metricbeat-modules.html
  sudo metricbeat modules enable system beat docker

  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/metricbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Metricbeat ingest pipeline",
  "processors": [
    {
      "pipeline": {
        "name": "geoip-info"
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply
}

configure_packetbeat() {
  configure_common packetbeat

  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/packetbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Packetbeat ingest pipeline",
  "processors": [
    {
      "pipeline": {
        "name": "geoip-info"
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply
}

# Configure a pipeline to add GeoIP data to ECS common fields
# Doc Ref: https://www.elastic.co/guide/en/beats/packetbeat/7.3/packetbeat-geoip.html
# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-geoip.html
configure_geoip_pipeline() {
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_DOMAIN}:9243/_ingest/pipeline/geoip-info" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Add geoip info",
  "processors": [
    {
      "geoip": {
        "field": "client.ip",
        "target_field": "client.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "source.ip",
        "target_field": "source.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "destination.ip",
        "target_field": "destination.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "server.ip",
        "target_field": "server.geo",
        "ignore_missing": true
      }
    },
    {
      "geoip": {
        "field": "host.ip",
        "target_field": "host.geo",
        "ignore_missing": true
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply

}


launch_via_systemd() {
  sudo systemctl enable $1
  sudo systemctl restart $1
}

##########################################################################
# Script starts here
#

install_on_$(lsb_release -is)

configure_geoip_pipeline

for beat in $BEATS2INSTALL; do
  BEAT=${beat%-elastic}

  configure_$BEAT

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/command-line-options.html#setup-command
  test -n "$ES_BEAT_SKIP_SETUP" || sudo $BEAT setup

  launch_via_systemd $beat
done

