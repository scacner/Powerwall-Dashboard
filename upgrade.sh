#!/bin/bash

# Stop on Errors
set -e

# Set Globals
VERSION="2.10.0"
CURRENT="Unknown"
COMPOSE_ENV_FILE="compose.env"
TELEGRAF_LOCAL="telegraf.local"
PW_ENV_FILE="pypowerwall.env"
if [ -f VERSION ]; then
    CURRENT=`cat VERSION`
fi

# Verify not running as root
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Running this as root will cause permission issues."
    echo ""
    echo "Please ensure your local user is in the docker group and run without sudo."
    echo "   sudo usermod -aG docker \$USER"
    echo "   $0"
    echo ""
    exit 1
fi

# Service Running Helper Function
running() {
    local url=${1:-http://localhost:80}
    local code=${2:-200}
    local status=$(curl --head --location --connect-timeout 5 --write-out %{http_code} --silent --output /dev/null ${url})
    [[ $status == ${code} ]]
}

# Because this file can be upgrade, don't use it to run the upgrade
if [ "$0" != "tmp.sh" ]; then
    # Grab latest upgrade script from github and run it
    curl -sL --output tmp.sh https://raw.githubusercontent.com/jasonacox/Powerwall-Dashboard/main/upgrade.sh
    exec bash tmp.sh upgrade
fi

# Check to see if an upgrade is available
if [ "$VERSION" == "$CURRENT" ]; then
    echo "WARNING: You already have the latest version (v${VERSION})."
    echo ""
fi

echo "Upgrade Powerwall-Dashboard from ${CURRENT} to ${VERSION}"
echo "---------------------------------------------------------------------"
echo "This script will attempt to upgrade you to the latest version without"
echo "removing existing data. A backup is still recommended."
echo ""

# Stop upgrade if the installation is missing key files
if [ ! -f ${PW_ENV_FILE} ]; then
    echo "ERROR: Missing ${PW_ENV_FILE} - This means you have not run 'setup.sh' or"
    echo "       you have an older version that cannot be updated automatically."
    echo "       Run 'git pull' and resolve any conflicts then run the 'setup.sh'"
    echo "       script to re-enter your Powerwall credentials."
    echo ""
    echo "Exiting"
    exit 1
fi

# Verify Upgrade
read -r -p "Upgrade - Proceed? [y/N] " response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]
then
    echo ""
else
    echo "Cancel"
    exit
fi

# Remember Timezone and Reset to Default
echo "Resetting Timezone to Default..."
DEFAULT="America/Los_Angeles"
TZ=`cat tz`
if [ -z "${TZ}" ]; then
    TZ="America/Los_Angeles"
fi
./tz.sh "${DEFAULT}"

# Pull from Github
echo ""
echo "Pull influxdb.sql, dashboard.json, telegraf.conf, and other changes..."
echo ""
git stash
git pull --rebase
echo ""

# Create Grafana Settings if missing (required in 2.4.0)
if [ ! -f grafana.env ]; then
    cp "grafana.env.sample" "grafana.env"
fi

# Check for latest Grafana settings (required in 2.6.2)
if ! grep -q "yesoreyeram-boomtable-panel-1.5.0-alpha.3.zip" grafana.env; then
    echo "Your Grafana environmental settings are outdated."
    read -r -p "Upgrade grafana.env? [y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]
    then
        cp "grafana.env" "grafana.env.bak"
        cp "grafana.env.sample" "grafana.env"
        echo "Updated"
        docker stop grafana
        docker rm grafana
    else
        echo "No Change"
    fi
fi

# Silently create default docker compose env file if needed.
if [ ! -f ${COMPOSE_ENV_FILE} ]; then
    cp "${COMPOSE_ENV_FILE}.sample" "${COMPOSE_ENV_FILE}"
else
    # Convert GRAFANAUSER to PWD_USER in existing compose env file (required in 2.10.0)
    sed -i.bak "s@GRAFANAUSER@PWD_USER@g" "${COMPOSE_ENV_FILE}"
    if grep -q "^PWD_USER=\"1000:1000\"" "${COMPOSE_ENV_FILE}"; then
        sed -i.bak "s@^PWD_USER=\"1000:1000\"@#PWD_USER=\"1000:1000\"@g" "${COMPOSE_ENV_FILE}"
    fi
fi

# Create default telegraf local file if needed.
if [ ! -f ${TELEGRAF_LOCAL} ]; then
    cp "${TELEGRAF_LOCAL}.sample" "${TELEGRAF_LOCAL}"
fi

# Check for PW_STYLE setting and add if missing
if ! grep -q "PW_STYLE" ${PW_ENV_FILE}; then
    echo "Your pypowerwall environmental settings are missing PW_STYLE."
    echo "Adding..."
    echo "PW_STYLE=grafana-dark" >> ${PW_ENV_FILE}
fi

# Check to see that TZ is set in pypowerwall
if ! grep -q "TZ=" ${PW_ENV_FILE}; then
    echo "Your pypowerwall environmental settings are missing TZ."
    echo "Adding..."
    echo "TZ=America/Los_Angeles" >> ${PW_ENV_FILE}
fi

# Check to see if Weather Data is Available
if [ ! -f weather/weather411.conf ]; then
    echo "This version (${VERSION}) allows you to add local weather data."
    echo ""
    # Optional - Setup Weather Data
    if [ -f weather.sh ]; then
        ./weather.sh setup
    else
        echo "However, you are missing the weather.sh setup file. Skipping..."
        echo ""
    fi
fi

# Set Timezone
echo ""
echo "Setting Timezone back to ${TZ}..."
./tz.sh "${TZ}"

# Update Powerwall-Dashboard stack
echo ""
echo "Updating Powerwall-Dashboard stack..."
./compose-dash.sh up -d

# Update Influxdb
echo ""
echo "Waiting for InfluxDB to start..."
until running http://localhost:8086/ping 204 2>/dev/null; do
    printf '.'
    sleep 5
done
echo " up!"
sleep 2
echo ""
echo "Add downsample continuous queries to InfluxDB..."
docker exec --tty influxdb sh -c "influx -import -path=/var/lib/influxdb/influxdb.sql"
cd influxdb
for f in run-once*.sql; do
    if [ ! -f "${f}.done" ]; then
        echo "Executing single run query $f file..."
        docker exec --tty influxdb sh -c "influx -import -path=/var/lib/influxdb/${f}"
        echo "OK" > "${f}.done"
    fi
done
cd ..

# Delete pyPowerwall
echo ""
echo "Deleting old pyPowerwall..."
docker stop pypowerwall
docker rm pypowerwall

# Delete telegraf
echo ""
echo "Deleting old telegraf..."
docker stop telegraf
docker rm telegraf

# Delete weather411
echo ""
echo "Deleting old weather411..."
docker stop weather411
docker rm weather411

# Restart Stack and Rebuild containers
echo ""
echo "Restarting Powerwall-Dashboard stack..."
./compose-dash.sh up -d

# Display Final Instructions
cat << EOF

---------------[ Update Dashboard ]---------------
Open Grafana at http://localhost:9000/

From 'Dashboard/Browse', select 'New/Import', and
upload 'dashboard.json' located in the folder
${PWD}/dashboards/

Please note, you may need to select data sources
for 'InfluxDB' and 'Sun and Moon' via the
dropdowns and use 'Import (Overwrite)' button.

EOF

# Clean up temporary upgrade script
rm -f tmp.sh
