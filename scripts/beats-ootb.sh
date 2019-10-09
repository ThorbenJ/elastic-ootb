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
# Optionally you can give the private IP addresses seen by this host
# a location by setting: (the example shown are Amsterdams co-ords)
# ES_SITE_LOCATION="52.3667:4.8945"
#
# Other variables in this script can be overriden by es-ootb.conf
#

# Avoid issues with locales
unset LANG LC_CTYPE LC_ALL

# Print the commands this script is executing
set -x

# Stop script if any command returns an (unhandled) error
set -e

# List of beats to install and configure
BEATS_LIST="metricbeat auditbeat packetbeat filebeat heartbeat-elastic"

# Helper print message and exit
_fail() {
  echo $@ >&2
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

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Unpack ES_CLOUD_ID
# The second part of the cloud ID, after the first colon ':' is just
# a base64 encoded string that contains the URLs for Elasticsearch and Kibana
# Beats understand cloud id natively, and this makes configuring them very easy
# however we need the plain URLs to use in some 'curl' commands below
ES_CLOUD_INFO=$(echo ${ES_CLOUD_ID#*:} | base64 -d -)
ES_SUFFIX=$(echo $ES_CLOUD_INFO | cut -d $ -f1)
ES_ELASRCH_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f2)
ES_KIBANA_HOST=$(echo $ES_CLOUD_INFO | cut -d $ -f3)

# Will we configure beats to monitor a docker host?
CONFIGURE4DOCKER=
ps -A | grep -v grep | grep -q dockerd && RC=0 || RC=$?  #Remember set -e
test "$RC" = "0" -a -S /var/run/docker.sock && CONFIGURE4DOCKER=1

###############################################################
# Functions
#

##### Installation ######


install_on_Debian() {

  # Test if we already added the elastic repository, and add it if not
  if ! test -f /etc/apt/sources.list.d/elastic-7.x.list ; then
  
    # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install apt-transport-https ca-certificates
  
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
  
    echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" \
      | sudo tee /etc/apt/sources.list.d/elastic-7.x.list >/dev/null
    
    sudo apt-get update
  fi
  
  # Install our list of beats
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install $BEATS_LIST
  
} # End: install_on_Debian

# Same as debian
# Not tested
install_on_Ubuntu() { install_on_Debian; }


install_on_CentOS() {

  # Test if we already added the elastic repository, and add it if not
  if ! test -f /etc/yum.repos.d/elastic.repo ; then
  
    # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/setup-repositories.html
    sudo rpm --import https://packages.elastic.co/GPG-KEY-elasticsearch

    # This "cat | sudo tee" construct is a way to write to a privileged files from a
    # non-privileged user, you will see this a lot in this script!
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

  # Install our list of beats
  sudo yum -y install $BEATS_LIST
  
} # End: install_on_CentOS

# Not tested
install_on_RHEL() { install_on_CentOS; }


##### Beats configuration #####


# Configuration for most beats
configure_common() {
  BEAT=$1
  BEAT_CONF="/etc/$1/$1.yml"
  test -f "$BEAT_CONF" || _fail "Beat config file missing: $BEAT_CONF"

  # Keep a copy of the original, if not already done
  test -f "${BEAT_CONF}.original" || sudo cp "${BEAT_CONF}" "${BEAT_CONF}.original"

  # This script always starts with a clean "original" copy of the config
  # This avoids multiple executions from appending the same thing multiple times
  sudo cp "${BEAT_CONF}.original" "${BEAT_CONF}"

  # Create keystore if it doesn't already exist
  echo n | sudo $BEAT --path.config /etc/$BEAT keystore create
  
  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/configure-cloud-id.html
  # Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/keystore.html
  # It is recommend to keep credentials in in the keystore rather than config file
#   echo $ES_CLOUD_ID | 
#     sudo $BEAT --path.config /etc/$BEAT keystore add cloud.id --stdin --force
#   echo $ES_CLOUD_AUTH | 
#     sudo $BEAT --path.config /etc/$BEAT keystore add cloud.auth --stdin --force
  
  
  # Append the following config snipet to the beat config file via sudo
  # NOTE for each beat we will create an ingest pipeline called "beatname-in"
  cat <<_EOF_ |

##### OOTB script appended all below here #####

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/configure-cloud-id.html
cloud.id: "$ES_CLOUD_ID"
cloud.auth: "$ES_CLOUD_AUTH"

# Doc Ref: https://www.elastic.co/guide/en/beats/metricbeat/current/elasticsearch-output.html#pipeline-option-es
output.elasticsearch.pipeline: "${BEAT}-in"

# Doc ref: https://www.elastic.co/guide/en/beats/metricbeat/current/monitoring-internal-collection.html
monitoring:
  enabled: true

# Prcessors should be last, so that beat specific configs (below) can append to it
processors:
- add_host_metadata:
    netinfo.enabled: true
- add_cloud_metadata: ~
_EOF_
  sudo tee -a "$BEAT_CONF" >/dev/null
  
  #
  # We will use the agent location for private IPs (if available)
  if [ -n "$ES_SITE_LOCATION" ]; then
  
      cat <<_EOF_ |
- add_fields:
    fields:
      agent.geo.location:
        lat: ${ES_SITE_LOCATION%:*}
        lon: ${ES_SITE_LOCATION#*:}
    target: ''
_EOF_
    sudo tee -a "$BEAT_CONF" >/dev/null
    
  fi # IF site location set

  
} # End: configure_common


configure_auditbeat() {
  configure_common auditbeat

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  # Configure the auditbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/auditbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
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

  # Most none default config settings are related to monitoring docker containers
  # So we only apply them if docker appears to be installed and running
  if [ -n "$CONFIGURE4DOCKER" ]; then
  
    # Repeated yaml entries completly overwrite/replace previous entries; so filebeat.inputs here overrides any previous configuration
    cat <<_EOF_ |
# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/add-docker-metadata.html
- add_docker_metadata: ~

filebeat.inputs:
# Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-input-container.html
- type: container
  paths:
    - '/var/lib/docker/containers/*/*.log'
#  json.keys_under_root: true
#  json.add_error_key: true
#  json.message_key: log

_EOF_
    sudo tee -a /etc/filebeat/filebeat.yml >/dev/null

  fi # End: IF Configure for docker

  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-modules.html
  sudo filebeat modules enable system apache

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  # Configure filebeat's ingest pipeline
  # NOTE some filebeat modules ship with their own ingest pipelines, for compatibility
  # we try to redirect to those pipelines, allowing us to also include ours
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/filebeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
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
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'nginx.error'",
        "name": "filebeat-{{_ingest.agent.version}}-nginx-error-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'mysql.error' ",
        "name": "filebeat-{{_ingest.agent.version}}-mysql-error-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'nginx.access'",
        "name": "filebeat-{{_ingest.agent.version}}-nginx-access-default"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'osquery.result'",
        "name": "filebeat-{{_ingest.agent.version}}-osquery-result-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'system.auth'",
        "name": "filebeat-{{_ingest.agent.version}}-system-auth-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'mysql.slowlog'",
        "name": "filebeat-{{_ingest.agent.version}}-mysql-slowlog-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'iptables.log'",
        "name": "filebeat-{{_ingest.agent.version}}-iptables-log-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'suricata.eve'",
        "name": "filebeat-{{_ingest.agent.version}}-suricata-eve-pipeline"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'logstash.slowlog'",
        "name": "filebeat-{{_ingest.agent.version}}-logstash-slowlog-pipeline-plain"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'logstash.log'",
        "name": "filebeat-{{_ingest.agent.version}}-logstash-log-pipeline-plain"
      }
    },
    {
      "pipeline": {
        "if": "ctx.agent?.version != null && ctx.event?.dataset == 'system.syslog'",
        "name": "filebeat-{{_ingest.agent.version}}-system-syslog-pipeline"
      }
    }
  ]
}
_EOF_
  echo #add a new line after the REST reply

## List of these seen so far...
#   filebeat-7.4.0-nginx-error-pipeline
#   filebeat-7.4.0-mysql-error-pipeline
#   filebeat-7.4.0-nginx-access-default
#   filebeat-7.4.0-osquery-result-pipeline
#   filebeat-7.4.0-system-auth-pipeline
#   filebeat-7.4.0-mysql-slowlog-pipeline
#   filebeat-7.4.0-iptables-log-pipeline
#   filebeat-7.4.0-suricata-eve-pipeline
#   filebeat-7.4.0-logstash-slowlog-pipeline-plain
#   filebeat-7.4.0-logstash-log-pipeline-plain
#   filebeat-7.4.0-system-syslog-pipeline
  
} # End: configure_filebeat


configure_heartbeat() {
  configure_common heartbeat

  # Add details of the heartbeat agent
  cat <<_EOF_ |
# Doc Ref: https://www.elastic.co/guide/en/beats/heartbeat/current/add-observer-metadata.html
- add_observer_metadata:
    netinfo.enabled: true
_EOF_
  sudo tee -a /etc/heartbeat/heartbeat.yml >/dev/null
  
  # Configure heartbeat to automatically monitor any container network endpoint
  # Without docker the default heartbeat monitor is localhost:9200, which likely does not exist
  if [ -n "$CONFIGURE4DOCKER" ]; then
  
    HOSTNAME=$(hostname -s)
    
    # need to excape beats ${} vars, otherwise bash will complain about ${data.host}, etc.
    cat <<_EOF_ |
# Doc Ref: https://www.elastic.co/guide/en/beats/heartbeat/current/add-docker-metadata.html
- add_docker_metadata: ~

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

_EOF_
    sudo tee -a /etc/heartbeat/heartbeat.yml >/dev/null

  fi # End: IF Configure for docker

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  # Create our heartbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/heartbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
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
  sudo metricbeat modules enable system apache docker

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  # Create our metricbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/metricbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
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

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  # Create our packetbeat pipeline
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/pipeline-processor.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/packetbeat-in" -H 'Content-Type: application/json' -d@- <<_EOF_
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
configure_geoip_pipeline() {

  # Skip if we're not to setup elasticsearch & kibana
  test -n "$ES_SKIP_SETUP_STEPS" && return
  
  #~~~~~~~~~~~~~~~~
  # We will only run geoip on one (prefarably public) IP address
  # So if the IP field is an array, we need to select one IP from it
  #
  # sed voodoo from: https://superuser.com/a/1296229
  # """ is kibana magic we have to recreate; converting new lines to literal \n
  SCRIPT=$(sed ':a;N;$!ba;s/\n/\\n/g' <<_EOF_
if (!ctx.containsKey(params.field) || !ctx[params.field].containsKey('ip') ) {
    return;
}

// Convert single ip to single entry in an array
def ips = ctx[params.field].ip instanceof List
    ? ctx[params.field].ip 
    : [ ctx[params.field].ip ];

def site_ip = '';
def public_ip =  '';

// No RegEx, as they are disabled by default
for ( def ip : ips ) {

    // We don't deal with IPv6 yet..
    if ( ip.indexOf(':') >= 0) {
      continue
    }
    
    if ( ip.startsWith('127.')
      || ip.startsWith('169.254.')
    ) {
      // Not interested in local ips
      continue
    }
    
    if ( ip.startsWith('10.')
      || ip.startsWith('192.168.')
      || ip.startsWith('172.16.')
      || ip.startsWith('172.17.')
      || ip.startsWith('172.18.')
      || ip.startsWith('172.19.')
      || ip.startsWith('172.20.')
      || ip.startsWith('172.21.')
      || ip.startsWith('172.22.')
      || ip.startsWith('172.23.')
      || ip.startsWith('172.24.')
      || ip.startsWith('172.25.')
      || ip.startsWith('172.26.')
      || ip.startsWith('172.27.')
      || ip.startsWith('172.28.')
      || ip.startsWith('172.29.')
      || ip.startsWith('172.30.')
      || ip.startsWith('172.31.')
    ) {
      // Private RFC1918 ips belong to the "site"
      site_ip = ip;
    }
    else {
      // public IPs can be mapped to world locations
      public_ip = ip;
    }
}

if ( public_ip != '') {

    // If we have a public IP use it for geo ip mapping
    ctx[params.field]._geo_ip = public_ip;
}
else if ( site_ip != '') {

    // If no public IP, try with the site IP
    ctx[params.field]._geo_ip = site_ip;
    
    // If agent.geo exists (set in the beat using ES_SITE_LOCATION above in configure_common() )
    // Then set a site IP's geo to the same as agent.geo
    if ( ctx.containsKey('agent') && ctx.agent.containsKey('geo') ) {
        ctx[params.field].geo = ctx.agent.geo;
    }
}
_EOF_
)

  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-scripting-using.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/painless/current/painless-guide.html
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_scripts/pick_geoip" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "script": {
    "lang": "painless",
    "source": "$SCRIPT"
  }
}
_EOF_

  #~~~~~~~~~~~~~~~~~~~~~~~`
  # We first use our pick_geoip script and then apply the geoip processor on the chosen IP
  #
  # Doc Ref: https://www.elastic.co/guide/en/beats/packetbeat/current/packetbeat-geoip.html
  # or
  # Doc Ref: https://www.elastic.co/guide/en/beats/filebeat/current/filebeat-geoip.html
  # and
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/ingest.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/geoip-processor.html
  # Doc Ref: https://www.elastic.co/guide/en/elasticsearch/reference/current/script-processor.html
  #
  curl -u "$ES_CLOUD_AUTH" -X PUT "https://${ES_ELASRCH_HOST}.${ES_SUFFIX}/_ingest/pipeline/geoip-info" -H 'Content-Type: application/json' -d@- <<_EOF_
{
  "description": "Add geoip info",
  "processors": [
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "client"
        }
      }
    },
    {
      "geoip": {
        "field": "client._geo_ip",
        "target_field": "client.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "source"
        }
      }
    },
    {
      "geoip": {
        "field": "source._geo_ip",
        "target_field": "source.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "destination"
        }
      }
    },
    {
      "geoip": {
        "field": "destination._geo_ip",
        "target_field": "destination.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "server"
        }
      }
    },
    {
      "geoip": {
        "field": "server._geo_ip",
        "target_field": "server.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "host"
        }
      }
    },
    {
      "geoip": {
        "field": "host._geo_ip",
        "target_field": "host.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "observer"
        }
      }
    },
    {
      "geoip": {
        "field": "observer._geo_ip",
        "target_field": "observer.geo",
        "ignore_missing": true
      }
    },
    {
      "script": {
        "id": "pick_geoip",
        "params": {
          "field": "monitor"
        }
      }
    },
    {
      "geoip": {
        "field": "monitor._geo_ip",
        "target_field": "monitor.geo",
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
  test -n "$ES_SKIP_SETUP_STEPS" || sudo $BEAT setup

  relaunch_via_systemd $beat #here we really want the service name
done

