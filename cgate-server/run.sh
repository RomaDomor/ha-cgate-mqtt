#!/usr/bin/env bashio
# vim: set ft=bash

set -e # Exit immediately if a command exits with a non-zero status.

# Define paths (use /data for persistent generated files if possible)
# If cgate.jar MUST run from /cgate and read config from /cgate/config, stick with that.
CGATE_DIR="/opt/cgate-server"
CONFIG_DIR="${CGATE_DIR}/config"
TAG_DIR="${CGATE_DIR}/tag"
LOG_DIR="${CGATE_DIR}/logs"
CONFIG_FILE="${CONFIG_DIR}/C-GateConfig.txt"
ACCESS_FILE="${CONFIG_DIR}/access.txt"
JAR_FILE="${CGATE_DIR}/cgate.jar" # Assuming jar is in /cgate

if [ ! -L "${CONFIG_DIR}" ] && [ -d "${CONFIG_DIR}" ]; then
    rm -rf ${CONFIG_DIR}
fi
if [ ! -L "${TAG_DIR}" ] && [ -d "${TAG_DIR}" ]; then
    rm -rf ${TAG_DIR}
fi
if [ ! -L "${LOG_DIR}" ] && [ -d "${LOG_DIR}" ]; then
    rm -rf ${LOG_DIR}
fi

# Ensure target directories exist
mkdir -p /config/config
mkdir -p /config/tag
mkdir -p /config/logs

# Create symlinks (logs too, so event.txt/sync errors survive restarts and
# are readable from the addon_config share)
ln -sf /config/config ${CONFIG_DIR}
ln -sf /config/tag ${TAG_DIR}
ln -sf /config/logs ${LOG_DIR}

# --- Keep the previous run's event log (1.0.9) ---
# C-Gate rolls logs/event.txt over at startup but restarts its daily index at 0, so the next
# rollover overwrites that day's event-<date>-0.txt (2026-11-18: the log of the 03:11 incident was
# lost that way). Move event.txt and the numbered files of today and yesterday (the container
# clock may be UTC while C-Gate names files in local time) out of its way first.
ARCHIVE_DIR="/config/logs/archive"
mkdir -p "${ARCHIVE_DIR}"
boot_ts="$(date +%Y%m%d-%H%M%S)"
today="$(date +%Y%m%d)"
yesterday="$(date -d "@$(( $(date +%s) - 86400 ))" +%Y%m%d 2>/dev/null || echo "${today}")"
for f in /config/logs/event.txt /config/logs/event-"${today}"-*.txt /config/logs/event-"${yesterday}"-*.txt; do
    if [ -f "${f}" ]; then
        mv "${f}" "${ARCHIVE_DIR}/${boot_ts}-$(basename "${f}")"
    fi
done
find "${ARCHIVE_DIR}" -type f -mtime +14 -delete 2>/dev/null || true
bashio::log.info "Previous event logs archived to ${ARCHIVE_DIR} (kept 14 days)"
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