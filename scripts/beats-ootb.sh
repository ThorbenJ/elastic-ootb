#!/bin/bash

################################################################
#
# This script attempts create an initial out-of-the-box beats deployment on the
# host it is run on. Please run it as a normal user that can execute sudo
# This script:-
# - is heavily annotated, so that you can use it as a reference
# - requires: sudo, curl, lsb_release
# - can run on: Debian, Ubuntu (etc.), Centos, RHEL (etc.)
# - will install the beats listed a few lines below (see BEATS_LIST)
# - will configure those beats for an Elastic Cloud deployment
#   (defined in es-ootb.conf, see below)
# - configure basic common features and docker host monitoring
# - configure ingest pipelines, to improve the experience in kibana
#
# It is expected that a file called "es-ootb.conf" will exist in the current
# working directory. This file must contain two variables:
# ES_CLOUD_ID="<YOUR CLOUD ID>"
# ES_CLOUD_AUTH="<YOUR CLOUD AUTH>"
#
# Other variables in this script can be overriden by es-ootb.conf
#

# Avoid issues locales
unset LANG LC_CTYPE LC_ALL

# Print the commands this script is executing
set -x

# Stop script if any command returns an error
set -e

# List of beats to install and configure
BEATS_LIST="metricbeat auditbeat packetbeat filebeat heartbeat-elastic"

# Helper print message and exit
_fail() {
  echo $@
  exit 1
}

# Test that programmes we are going to use are installed
for c in curl sudo lsb_release; do
  test -x "$(which $c)" || _fail "Programme '$c' appears to be missing"
done

# Read config variables
test -f es-ootb.conf || _fail "Config file es-ootb.conf missing"
. es-ootb.conf

# Check config variables are set
test -n "$ES_CLOUD_ID" || _fail "ES_CLOUD_ID missing from es-ootb.conf"
test -n "$ES_CLOUD_AUTH" || _fail "ES_CLOUD_AUTH missing from es-ootb.conf"

# Unpack ES_CLOUD_ID
ES_CLOUD_INFO=$(echo ${ES_CLOUD_ID#*:} | base64 -d -)
ES_DOMAIN=$(echo $ES_CLOUD_INFO | cut -d $ -f1)
ES_ELASRCH_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f2)
ES_KIBANA_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f3)

# Will we configure beats to monitor a docker host?
CONFIGURE4DOCKER=
test -S /var/run/docker.sock && CONFIGURE4DOCKER=1

###############################################################
# Functions
#

##### Installation ######

# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
# Fully tested
install_on_Debian() {

  if ! test -f /etc/apt/sources.list.d/elastic-7.x.list ; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install apt-transport-https ca-certificates
  
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
  
    echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" \
      | sudo tee /etc/apt/sources.list.d/elastic-7.x.list >/dev/null
    
    sudo apt-get update
  fi
  
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install $BEATS_LIST
  
} # End: install_on_Debian

# Same as debian
# Not tested
install_on_Ubuntu() { install_on_Debian; }


# As per: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
# Tested without docker
install_on_CentOS() {

  if ! test -f /etc/yum.repos.d/elastic.repo ; then
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
  fi

  sudo yum -y install $BEATS_LIST
  
} # End: install_on_CentOS

# Not tested
install_on_RHEL() { install_on_CentOS; }


##### Beats configuration #####


# Configuration for most beats
configure_common() {
  BEAT_CONF="/etc/$1/$1.yml"
  test -f "$BEAT_CONF" || _fail "Beat config file missing: $BEAT_CONF"

  # Keep a copy of the original, if not already done
  test -f "${BEAT_CONF}.original" || sudo cp "${BEAT_CONF}" "${BEAT_CONF}.original"

  # This script always starts with a clean "original" copy of the config
  # This avoids multiple executions from appending the same thing multiple times
  sudo cp "${BEAT_CONF}.original" "${BEAT_CONF}"

  # Append the following config snipet to the beat config file via sudo
  # NOTE each beat will create an ingest pipeline called "beatname-in"
  cat <<_EOF_ |

## OOTB script appended all below here ##

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/configure-cloud-id.html
cloud.id: "$ES_CLOUD_ID"
cloud.auth: "$ES_CLOUD_AUTH"

# Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/elasticsearch-output.html#pipeline-option-es
output.elasticsearch.pipeline: "${1}-in"

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/monitoring-internal-collection.html
monitoring:
  enabled: true

_EOF_
  sudo tee -a "$BEAT_CONF" >/dev/null
  
} # End: configure_common


configure_auditbeat() {
  configure_common auditbeat

  # Configure auditbeat to use our (ECS) geoip pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
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
  
} # End: configure_auditbeat


configure_filebeat() {
  configure_common filebeat

  # Most none default config setting related to monitoring docker containers
  if [ -n "$CONFIGURE4DOCKER" ]; then
  
    # Repeated yaml entries completly overwrite/replace previous entries; so filebeat.inputs here overrides any previous configuration
    cat <<_EOF_ |
filebeat.inputs:
# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-container.html
- type: container
  paths:
    - '/var/lib/docker/containers/*/*.log'
#  json.keys_under_root: true
#  json.add_error_key: true
#  json.message_key: log

# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/add-docker-metadata.html
processors:
  - add_docker_metadata: ~
  - add_host_metadata: ~
  - add_cloud_metadata: ~

_EOF_
    sudo tee -a /etc/filebeat/filebeat.yml >/dev/null

  fi # End: IF Configure for docker

  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-modules.html
  sudo filebeat modules enable system 

  # Configure filebeat's ingest pipeline
  # NOTE some filebeat modules ship with their own ingest pipelines, for compatibility
  # we try to redirect to those pipelines
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
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
        "if": "ctx.fileset.name == 'iptables'",
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
  
} # End: configure_filebeat


configure_heartbeat() {
  configure_common heartbeat

  # Configure heartbeat to automatically monitor any container network endpoints
  # Without docker the default heartbeat monitor is localhost:9200, which likely does not exist
  if [ -n "$CONFIGURE4DOCKER" ]; then
  
    HOSTNAME=$(hostname -s)
    
    # single quote ' _EOF_ to disable shell substituion, otherwise bash will complain about ${data.host}, etc.
    cat <<_EOF_ |
# Disable previously configured monitors
heartbeat.monitors: ~

# Doc Ref: https://www.elastic.co/guide/en/beats/heartbeat/current/configuration-autodiscover.html
heartbeat.autodiscover:
  providers:
    - type: docker
      templates:
        - config:
          - type: tcp
            id: "\${data.docker.container.id}-\${data.port}"
            name: "${HOSTNAME}_\${data.docker.container.name}_\${data.port}"
            fields.docker_info: \${data.docker}
            hosts: ["\${data.host}:\${data.port}"]
            schedule: "@every 10s"
            timeout: 1s

# Doc Ref: https://www.elastic.co/guide/en/beats/heartbeat/current/add-docker-metadata.html
processors:
- add_observer_metadata: ~
- add_docker_metadata: ~

_EOF_
    sudo tee -a /etc/heartbeat/heartbeat.yml >/dev/null

  fi # End: IF Configure for docker

  # Create our heartbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
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
  
} # End: configure_heartbeat


configure_metricbeat() {
  configure_common metricbeat

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/metricbeat-modules.html
  sudo metricbeat modules enable system beat docker

  # Create our metricbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
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
  
} # End: configure_metricbeat


configure_packetbeat() {
  configure_common packetbeat

  # Create our packetbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
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
  
} # End: configure_packetbeat


# Configure a pipeline to add GeoIP data to ECS common fields
# Doc Ref: https://www.elastic.co/guide/en/beats/packetbeat/current/packetbeat-geoip.html
# or
# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-geoip.html
# and
# Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
# Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/geoip-processor.html
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

} # End: configure_geoip_pipeline


relaunch_via_systemd() {
  sudo systemctl enable $1
  sudo systemctl restart $1
}

###########################################################################
# Script starts here
#

# e.g. install_on_Debian or install_on_CentOS
install_on_$(lsb_release -is)

configure_geoip_pipeline

for beat in $BEATS_LIST; do

  # Handle heartbeat having a package/service-name of heartbeat-elastic
  BEAT=${beat%-elastic}

  configure_$BEAT

  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/command-line-options.html#setup-command
  test -n "$ES_BEAT_SKIP_SETUP" || sudo $BEAT setup

  relaunch_via_systemd $beat #here we really want the service name
done

