#!/usr/bin/env bashio
# vim: set ft=bash

set -e

# Read options from config
CBUSIP=$(bashio::config 'cbusip')
CBUSNAME=$(bashio::config 'cbusname')
MQTT=$(bashio::config 'mqtt')
MQTTUSERNAME=$(bashio::config 'mqttusername')
MQTTPASSWORD=$(bashio::config 'mqttpassword')
ENABLEHASSDISCOVERY=$(bashio::config 'enableHassDiscovery')
GETALLONSTART=$(bashio::config 'getallonstart')
GETALLNETAPP=$(bashio::config 'getallnetapp')
GETALLPERIOD=$(bashio::config 'getallperiod')
RETAINREADS=$(bashio::config 'retainreads')
MESSAGEINTERVAL=$(bashio::config 'messageinterval')
LOGGING=$(bashio::config 'logging')

# Generate settings.js from HA options
cat <<EOF > /usr/src/app/settings.js
//C-GATE IP Address
exports.cbusip = '${CBUSIP}';

//cbus project name
exports.cbusname = "${CBUSNAME}";

//mqtt server ip:port (my Home Assistant MQTT Broker)
exports.mqtt = '${MQTT}';
exports.mqttusername = '${MQTTUSERNAME}';
exports.mqttpassword = '${MQTTPASSWORD}';

// Map the C-Bus project information to Home Assistant Discovery Messages
exports.enableHassDiscovery = ${ENABLEHASSDISCOVERY};

// These should not need to be changed
exports.getallonstart = ${GETALLONSTART};
exports.getallnetapp = '${GETALLNETAPP}';
exports.getallperiod = ${GETALLPERIOD};
exports.retainreads = ${RETAINREADS};
exports.messageinterval = ${MESSAGEINTERVAL};

//logging
exports.logging = ${LOGGING};
EOF

# Copy HOME.xml if present
if [ -f /config/tag/HOME.xml ]; then
  cp /config/tag/HOME.xml /usr/src/app/HOME.xml
fi

# Start the main process
exec node index.js
