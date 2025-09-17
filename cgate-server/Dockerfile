# Use the HA build environment base image
ARG BUILD_FROM
FROM $BUILD_FROM

# Install Java (e.g., Java 17 LTS) + curl + unzip using Alpine's package manager 'apk'
RUN apk add --no-cache \
    openjdk8-jre \
    curl \
    unzip \
    netcat-openbsd \
    ca-certificates

# # Define ARG for download URL
# ARG CGATE_DOWNLOAD_URL=https://download.schneider-electric.com/files?p_File_Name=cgate-2.11.8_3282.zip
RUN SEC_FILE="/usr/lib/jvm/java-1.8-openjdk/jre/lib/security/java.security" && \
    if [ -f "$SEC_FILE" ]; then \
    sed -i \
    -e 's/\<TLSv1, \?//g' \
    -e 's/\<TLSv1\.1, \?//g' \
    "$SEC_FILE" && \
    grep -n '^jdk\.tls\.disabledAlgorithms=' "$SEC_FILE"; \
    else \
    echo "Warning: $SEC_FILE not found; skipping TLS patch"; \
    fi

# Install C-Gate
COPY cgate.zip /tmp/cgate.zip
RUN unzip /tmp/cgate.zip -d /opt && \
    rm /tmp/cgate.zip && \
    mv /opt/cgate /opt/cgate-server && \
    echo "C-Gate copied and extracted to /opt/cgate-server"

# Healthcheck
RUN mkdir -p /opt/health
COPY --chmod=0755 healthcheck.sh /opt/health/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD /opt/health/healthcheck.sh

# Set workdir where jar will run (or adjust run.sh)
WORKDIR /opt/cgate-server
COPY --chmod=0755 run.sh /run.sh

# Define entrypoint - run.sh will handle runtime setup
EXPOSE 20023 20123
ENTRYPOINT ["/run.sh"]