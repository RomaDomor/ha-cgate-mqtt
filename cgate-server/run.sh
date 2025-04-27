#!/usr/bin/env bashio
# vim: set ft=bash

set -e # Exit immediately if a command exits with a non-zero status.

# Define paths (use /data for persistent generated files if possible)
# If cgate.jar MUST run from /cgate and read config from /cgate/config, stick with that.
CGATE_DIR="/opt/cgate-server"
CONFIG_DIR="${CGATE_DIR}/config"
TAG_DIR="${CGATE_DIR}/tag"
CONFIG_FILE="${CONFIG_DIR}/C-GateConfig.txt"
ACCESS_FILE="${CONFIG_DIR}/access.txt"
JAR_FILE="${CGATE_DIR}/cgate.jar" # Assuming jar is in /cgate

if [ ! -L "${CONFIG_DIR}" ] && [ -d "${CONFIG_DIR}" ]; then
    rm -rf ${CONFIG_DIR}
fi
if [ ! -L "${TAG_DIR}" ] && [ -d "${TAG_DIR}" ]; then
    rm -rf ${TAG_DIR}
fi

# Ensure target directories exist
mkdir -p /config/config
mkdir -p /config/tag

# Create symlinks
ln -sf /config/config ${CONFIG_DIR}
ln -sf /config/tag ${TAG_DIR}
# --- Generate access.txt from UI options ---
bashio::log.info "Generating C-Gate access control file (${ACCESS_FILE})..."

# Clear existing file
: > "${ACCESS_FILE}"

# Check if the 'access_entries' option exists in the configuration
if bashio::config.has_value 'access_entries'; then
    bashio::log.info "Writing access_entries to ${ACCESS_FILE}..."
    IFS=$'\n' read -r -d '' -a access_entries < <(bashio::config 'access_entries' && printf '\0')
    for entry in "${access_entries[@]}"; do
        # Skip empty or comment lines
        if [[ -n "$entry" && ! "$entry" =~ ^# ]]; then
            echo "$entry" >> "${ACCESS_FILE}"
            bashio::log.info "- Added: ${entry}"
        fi
    done
else
    bashio::log.warning "Config option 'access_entries' not found. ${ACCESS_FILE} will be empty."
fi


bashio::log.info "${ACCESS_FILE} generation complete."

# --- Get other configuration options ---
# You need to determine how cgate.jar uses these options.
# Examples: Command line args? Java System Properties (-Dkey=value)? Another config file?

# ACCEPT_CONN_FROM=$(bashio::config 'accept_connections_from')
# ALLOW_FAST_START=$(bashio::config 'allow_fast_start')

# bashio::log.info "Using 'accept_connections_from': ${ACCEPT_CONN_FROM}"
# bashio::log.info "Using 'allow_fast_start': ${ALLOW_FAST_START}"

# --- Launch C-Gate Server ---
bashio::log.info "Starting C-Gate Server (${JAR_FILE})..."

# Change to the application directory if necessary
cd "${CGATE_DIR}"

# Execute the Java application
# Modify the command below if ACCEPT_CONN_FROM or ALLOW_FAST_START
# need to be passed as arguments or system properties.
# Example with system properties:
# exec java \
#   -Daccept.connections.from="${ACCEPT_CONN_FROM}" \
#   -Dallow.fast.start="${ALLOW_FAST_START}" \
#   -jar "${JAR_FILE}"

# Simple execution:
exec java -jar "${JAR_FILE}"

# If the java command fails, the script will exit due to 'set -e'
# and bashio will log the termination.