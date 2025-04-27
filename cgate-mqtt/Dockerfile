# Use the HA build environment base image
ARG BUILD_FROM
FROM $BUILD_FROM

# Install dependencies
RUN apk update && apk add --no-cache nodejs npm busybox-extras

# Create app directory
WORKDIR /usr/src/app

# Copy package files and install dependencies
COPY src/package*.json ./
RUN npm install

# Copy app source
COPY src/ .

# Copy and set permissions for run.sh
COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Set entrypoint
ENTRYPOINT [ "/run.sh" ]
