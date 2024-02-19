#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 and install Uptime-Kuma
# git clone https://github.com/tschettervictor/truenas-iocage-uptimekuma

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
JAIL_NAME="uptimekuma"
CONFIG_NAME="uptimekuma-config"

# Check for uptimekuma-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi 

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by uptimekuma-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "git-lite",
  "npm-node18"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

# Create and mount directories
mkdir -p "${POOL_PATH}"/uptimekuma/data
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" mkdir -p /var/run/uptimekuma/

#####
#
# Uptime-Kuma Installation 
#
#####

iocage exec "${JAIL_NAME}" "pw user add uptimekuma -c uptimekuma -u 3001 -d /nonexistent -s /usr/bin/nologin"
iocage exec "${JAIL_NAME}" "npm install npm -g"
iocage exec "${JAIL_NAME}" "cd /usr/local/ && git clone https://github.com/louislam/uptime-kuma.git"
iocage exec "${JAIL_NAME}" "mkdir /usr/local/uptime-kuma/data"
iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}"/uptimekuma /usr/local/uptime-kuma/data nullfs rw 0 0
iocage exec "${JAIL_NAME}" "cd /usr/local/uptime-kuma && npm run setup"
iocage exec "${JAIL_NAME}" sed -i '' "s|console.log(\"Welcome to Uptime Kuma\");|process.chdir('/usr/local/uptime-kuma');\n&|" /usr/local/uptime-kuma/server/server.js
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/uptimekuma /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" "chown -R uptimekuma:uptimekuma /usr/local/uptime-kuma"
iocage exec "${JAIL_NAME}" "chown -R uptimekuma:uptimekuma /var/run/uptimekuma"
iocage exec "${JAIL_NAME}" sysrc uptimekuma_enable="YES"

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

# Restart
iocage restart "${JAIL_NAME}"

echo "---------------"
echo "Installation Complete!"
echo "---------------"
echo "Using your web browser, go to http://${IP}:3001 to log in"
echo "---------------"
echo "New installs will ask to create admin user on startup."
echo "If this is a reinstall, use your old user and password."
