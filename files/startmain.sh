#!/bin/bash

#
# Make the rings if they don't exist already
#

# These can be set with docker run -e VARIABLE=X at runtime
SWIFT_PART_POWER=${SWIFT_PART_POWER:-7}
SWIFT_PART_HOURS=${SWIFT_PART_HOURS:-1}
SWIFT_REPLICAS=${SWIFT_REPLICAS:-1}

if [ -e /srv/account.builder ]; then
	echo "Ring files already exist in /srv, copying them to /etc/swift..."
	cp /srv/*.builder /etc/swift/
	cp /srv/*.gz /etc/swift/
fi

# This comes from a volume, so need to chown it here, not sure of a better way
# to get it owned by Swift.
chown -R swift:swift /srv

if [ ! -e /etc/swift/account.builder ]; then

	cd /etc/swift

	# 2^& = 128 we are assuming just one drive
	# 1 replica only

	echo "No existing ring files, creating them..."

	swift-ring-builder object.builder create ${SWIFT_PART_POWER} ${SWIFT_REPLICAS} ${SWIFT_PART_HOURS}
	swift-ring-builder object.builder add r1z1-127.0.0.1:6010/sdb1 1
	swift-ring-builder object.builder rebalance
	swift-ring-builder container.builder create ${SWIFT_PART_POWER} ${SWIFT_REPLICAS} ${SWIFT_PART_HOURS}
	swift-ring-builder container.builder add r1z1-127.0.0.1:6011/sdb1 1
	swift-ring-builder container.builder rebalance
	swift-ring-builder account.builder create ${SWIFT_PART_POWER} ${SWIFT_REPLICAS} ${SWIFT_PART_HOURS}
	swift-ring-builder account.builder add r1z1-127.0.0.1:6012/sdb1 1
	swift-ring-builder account.builder rebalance

	# Back these up for later use
	echo "Copying ring files to /srv to save them if it's a docker volume..."
	cp *.gz /srv
	cp *.builder /srv

fi

IFS=':' read -r -a array <<< "${SWIFT_CREDENTIALS}"
SWIFT_USER_LINES=`printf "%s\n"  "${array[@]}"`

echo "Configuring dispersion..."
eval "echo \"$(</default/dispersion.conf)\"" 2> /dev/null > /etc/swift/dispersion.conf

echo "Configuring Users..."
eval "echo \"$(</default/proxy-server.conf)\"" 2> /dev/null > /etc/swift/proxy-server.conf


# If you are going to put an ssl terminator in front of the proxy, then I believe
# the storage_url_scheme should be set to https. So if this var isn't empty, set
# the default storage url to https.
if [ ! -z "${SWIFT_STORAGE_URL_SCHEME}" ]; then
        echo "Setting default_storage_scheme to https in proxy-server.conf..."
        sed -i -e "s/storage_url_scheme = default/storage_url_scheme = https/g" /etc/swift/proxy-server.conf
        grep "storage_url_scheme" /etc/swift/proxy-server.conf
fi


# Start supervisord
echo "Starting supervisord..."
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

# Create default container
if [ ! -z "${SWIFT_DEFAULT_CONTAINER}" ]; then
	echo "Creating default container..."
    swift -A http://localhost:8080/auth/v1.0 -U ${SWIFT_ADMIN_ACOUNT}:${SWIFT_ADMIN_USER} -K ${SWIFT_ADMIN_KEY} post ${SWIFT_DEFAULT_CONTAINER}
fi

# Create meta-url-key to allow temp download url generation
if [ ! -z "${SWIFT_TEMP_URL_KEY}" ]; then
  echo "Setting X-Account-Meta-Temp-URL-Key..."
  swift -A http://localhost:8080/auth/v1.0 -U  ${SWIFT_ADMIN_ACOUNT}:${SWIFT_ADMIN_USER} -K ${SWIFT_ADMIN_KEY} post -m "Temp-URL-Key:${SWIFT_TEMP_URL_KEY}"
fi

#
# Tail the log file for "docker log $CONTAINER_ID"
#

# sleep waiting for rsyslog to come up under supervisord
sleep 3

echo "Starting to tail /var/log/syslog...(hit ctrl-c if you are starting the container in a bash shell)"

tail -n 0 -f /var/log/syslog
