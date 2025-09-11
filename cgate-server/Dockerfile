# Use the HA build environment base image
ARG BUILD_FROM
FROM $BUILD_FROM

# Install Java (e.g., Java 17 LTS) + curl + unzip using Alpine's package manager 'apk'
RUN apk update && \
    apk add --no-cache \
    openjdk17-jre \
    curl \
    unzip \
    ca-certificates && \
    echo "Packages installed."

# # Define ARG for download URL
# ARG CGATE_DOWNLOAD_URL=https://download.schneider-electric.com/files?p_File_Name=cgate-2.11.8_3282.zip

# # Create app directory, download, unzip, cleanup in one layer
# # Using /opt is a common practice for manually installed software
# WORKDIR /app # Temporary workdir for download
# RUN curl -f -L ${CGATE_DOWNLOAD_URL} -o cgate.zip && \
#     unzip cgate.zip -d /opt && \
#     rm cgate.zip && \
#     mv /opt/cgate /opt/cgate-server && \
#     echo "C-Gate downloaded and extracted to /opt/cgate-server"
COPY cgate.zip /tmp/cgate.zip
RUN unzip /tmp/cgate.zip -d /opt && \
    rm /tmp/cgate.zip && \
    mv /opt/cgate /opt/cgate-server && \
    echo "C-Gate copied and extracted to /opt/cgate-server"

# Set workdir where jar will run (or adjust run.sh)
WORKDIR /opt/cgate-server

# Copy the run script
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Define entrypoint - run.sh will handle runtime setup
ENTRYPOINT ["/run.sh"]