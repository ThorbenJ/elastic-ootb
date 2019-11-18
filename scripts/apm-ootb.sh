#!/bin/bash

#####################################################################
#
# This script with deploy and attach an APM java agent to all docker
# containers that appear to be running a java application
# It is mainly intended to be used with the accompanying webgoat_on_docker.sh
# script, but is not limited to this.
# This script:-
# - is annoted with documentation references
# - can run on: Debian, Ubuntu (etc.), Centos, RHEL (etc.)
# - will wait for more/new containers if given the argument "wait4more"
# - requires: sudo, curl, lsb_release
# - will install maven to be able to fetch the agent Jar file
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

# Read config variables
test -f es-ootb.conf || _fail "Config file es-ootb.conf missing"
. es-ootb.conf

# Check config variables are set
test -n "$ES_APM_SERVER" || _fail "ES_APM_SERVER missing from es-ootb.conf"
test -n "$ES_APM_TOKEN" || _fail "ES_APM_TOKEN missing from es-ootb.conf"

# Where to get the latest RUM agent from
ES_APM_RUM_URL="https://github.com/elastic/apm-agent-rum-js/releases/latest/download/elastic-apm-rum.umd.min.js"

# The APM RUM agent JS script needs to be loaded into the web page
# Doc Ref: https://www.elastic.co/guide/en/apm/server/current/configuration-rum.html
#
# Instead of changing the HTML source, we will use Apache's substitute module to
# inject the needed script tags to all pages
# We use the first dir as service name (e.g. "/WebGoat")
ES_APM_RUM_APACHE_CONF=$( cat <<_EOF_
AddOutputFilterByType SUBSTITUTE text/html
Substitute "s|</body>|\
<script src='/elastic-apm-rum.umd.min.js' crossorigin></script>\
<script> \
var rum_svc_name = window.location.pathname; \
rum_svc_name = rum_svc_name.substring(0, rum_svc_name.indexOf('/', 1)).replace(/[^0-9a-zA-Z]/g, '_'); \
elasticApm.init({ serviceName: rum_svc_name, serverUrl: '$ES_APM_SERVER' }); \
</script>\
</body>|n"
_EOF_
)

test -S /var/run/docker.sock || _fail "Docker does not appear to be running"

###############################################################
# Functions
#

relaunch_via_systemd() {
  sudo systemctl enable $1
  sudo systemctl restart $1
}

display_apm_rum_config_msg() {

  cat <<_EOF_
################################################################
#           *** ENABLE RUM ON YOUR APM SERVER ***              #
#--------------------------------------------------------------#
#                                                              #
# 1) GOTO: https://cloud.elastic.co/ & login                   #
# 2) Select your deployment and click "Edit" in the left menu  #
# 3) Scroll down to "APM" and click "User Setting Overrides"   #
# 4) Add the following lines and Click "Save"                  #

apm-server.rum.enabled: true
apm-server.rum.allow_origins: ['*']

################################################################
_EOF_

}

##### Installation ######

install_on_Debian() {
  
  # This will pull in the default JDK and its many mnay dependencies, unfortunately
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y install maven apache2
  
  # We use the substitute module in insert the APM RUM script
  sudo a2enmod substitute
  
  # Fetch the APM RUM script and copy into www docs
  curl -L "$ES_APM_RUM_URL" -o /tmp/elastic-apm-rum.umd.min.js
  sudo cp /tmp/elastic-apm-rum.umd.min.js /var/www/html/elastic-apm-rum.umd.min.js
  
  echo "$ES_APM_RUM_APACHE_CONF" | sudo tee /etc/apache2/conf-enabled/es-apm-rum.conf >/dev/null
  
  relaunch_via_systemd apache2
  
} # End: install_on_Debian

# Same as debian
# Not tested
install_on_Ubuntu() { install_on_Debian; }

install_on_CentOS() {

  # This will pull in the default JDK and its many mnay dependencies, unfortunately
  sudo yum -y install maven httpd
  
  # We use the substitute module in insert the APM RUM script
  # Already loaded on a default CentOS install
  
  # Fetch the APM RUM script and copy into www docs
  curl -L "$ES_APM_RUM_URL" -o /tmp/elastic-apm-rum.umd.min.js
  sudo cp /tmp/elastic-apm-rum.umd.min.js /var/www/html/elastic-apm-rum.umd.min.js
  
  echo "$ES_APM_RUM_APACHE_CONF" | sudo tee /etc/httpd/conf.d/es-apm-rum.conf >/dev/null
  
  relaunch_via_systemd httpd
  
} # End: install_on_CentOS

# Not tested
install_on_RHEL() { install_on_CentOS; }

# Doc Ref: https://www.elastic.co/guide/en/apm/agent/java/current/setup-attach-cli.html
fetch_apm_agent() {

  # The version of mvn on CentOS is too old, so one needs to use an explicit plugin version
  #mvn dependency:get -Dartifact=co.elastic.apm:apm-agent-attach:LATEST:jar:standalone >&2
  mvn org.apache.maven.plugins:maven-dependency-plugin:2.10:get \
     -Dartifact=co.elastic.apm:apm-agent-attach:LATEST:jar:standalone >&2
     
  JAR=$(find $HOME -iname apm-agent-attach-\*-standalone.jar | tail -n1 )
  
  test -f "$JAR" || _fail "Failed to fetch apm agent attach"
  
  echo $JAR
}


###########################################################################
# Script starts here
#

display_apm_rum_config_msg

# e.g. install_on_Debian or install_on_CentOS
install_on_$(lsb_release -is)

AAAS_JAR=$( fetch_apm_agent )

# Doc Ref: https://www.elastic.co/guide/en/apm/agent/java/current/setup-attach-cli.html#setup-attach-cli-docker
# The code below is adapted from the docs ^

# FIXME avoid attaching more than once!
attach_apm_agent () {
# only attempt attachment if this looks like a java container
  if docker inspect "${container_id}" |  grep -q \\bjava\\b ; then
  
    echo attaching to $(docker ps --no-trunc | grep "${container_id}")
    docker cp "$AAAS_JAR" "${container_id}:/apm-agent-attach-standalone.jar"
    docker exec "${container_id}" java -jar /apm-agent-attach-standalone.jar \
      -C "server_urls=$ES_APM_SERVER" -C "secret_token=$ES_APM_TOKEN"
      
  fi # End: IF container has java
} # End: attach_apm_agent

# attach to running containers
for container_id in $(docker ps --quiet --no-trunc) ; do
  attach_apm_agent
done

if [ "$1" = "wait4more" ]; then
  # listen for starting containers and attach to those
  docker events --filter 'event=start' --format '{{.ID}}' | 
  while IFS= read -r container_id;   do
    attach_apm_agent
  done
fi # End: IF wait for more

display_apm_rum_config_msg
