#!/bin/sh

# Ensure access.txt exists with default content if not present
if [ ! -f /config/access.txt ]; then
  echo "interface 172.0.0.0/8" > /config/access.txt
fi

# Symlink logs to stdout/stderr if possible, or tail log files
LOGFILE="/logs/cgate.log"
if [ -f "$LOGFILE" ]; then
  tail -F "$LOGFILE" &
fi

# Start C-Gate server (replace with actual entrypoint if needed)
exec /entrypoint.sh