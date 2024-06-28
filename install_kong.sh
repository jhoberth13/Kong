#!/bin/bash
set -euo pipefail

KONG_PACKAGE_NAME=kong-enterprise-edition
KONG_PACKAGE_VERSION=

function determine_os() {
  UNAME=$(uname | tr "[:upper:]" "[:lower:]")
  # If Linux, try to determine specific distribution
  if [ "$UNAME" == "linux" ]; then
      if [[ -f "/etc/os-release" ]]; then
          export DISTRO=$(awk -F= '/^NAME/{ gsub(/"/, "", $2); print $2}' /etc/os-release)
          export VERSION="$(awk -F= '/^VERSION_ID/{ gsub(/"/, "", $2); print $2}' /etc/os-release)"
      fi
  fi
  # For everything else (or if above failed), just use generic identifier
  [ "${DISTRO-x}" == "x" ] && export DISTRO=$UNAME
  unset UNAME
}

function os_install_ubuntu() {
    if [[ -n "$KONG_PACKAGE_VERSION" ]]; then
        KONG_PACKAGE="$KONG_PACKAGE_NAME=$KONG_PACKAGE_VERSION"
    else
        KONG_PACKAGE="$KONG_PACKAGE_NAME"
    fi

    echo
    echo "########################################################"
    echo "Installing $KONG_PACKAGE on Ubuntu"
    echo "########################################################"
    echo

    export DEBIAN_FRONTEND=noninteractive

    echo "Checking installed packages"

    # If sudo is not installed
    if [[ $(dpkg-query -W -f='${Status}' sudo 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        apt-get update > /dev/null
        DEBCONF_NOWARNINGS=yes apt-get install -y sudo > /dev/null
    else
        sudo apt-get update > /dev/null
    fi

    # Ensure we have all the packages we need
    DEBCONF_NOWARNINGS=yes TZ=Etc/UTC sudo -E apt-get -y install tzdata lsb-release ca-certificates > /dev/null 2>&1

    # Configure Kong repo if needed
    if [[ ! -f /etc/apt/sources.list.d/kong.list ]]; then
        echo "Adding Kong repo"
        #echo "deb [trusted=yes] https://download.konghq.com/gateway-3.x-ubuntu-$(lsb_release -sc)/ \
# default all" | sudo tee /etc/apt/sources.list.d/kong.list > /dev/null
        sudo apt-get update > /dev/null
    fi

    # If $KONG_PACKAGE is not installed
    if [[ $(dpkg-query -W -f='${Status}' $KONG_PACKAGE 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        echo "Installing $KONG_PACKAGE"
        #DEBCONF_NOWARNINGS=yes sudo -E apt-get install -y $KONG_PACKAGE > /dev/null
        wget https://packages.konghq.com/public/gateway-35/deb/ubuntu/pool/jammy/main/k/ko/kong-enterprise-edition-fips_3.5.0.6/kong-enterprise-edition-fips_3.5.0.6_amd64.deb -O /tmp/kong-enterprise-edition
        DEBCONF_NOWARNINGS=yes sudo -E sudo dpkg -i /tmp/$KONG_PACKAGE > /dev/null
    else
        echo "$KONG_PACKAGE already installed"
    fi

    # If postgresql is not installed
    if [[ $(dpkg-query -W -f='${Status}' postgresql 2>/dev/null | grep -c "ok installed") -eq 0 ]]; then
        echo "Installing postgresql"
        DEBCONF_NOWARNINGS=yes sudo -E apt-get install -y postgresql > /dev/null
    else
        echo "Postgres already installed"
    fi

    # Start Postgres
    sudo /etc/init.d/postgresql start > /dev/null
}

function run_os_install(){
    determine_os

    IS_ENTERPRISE=1
    if [[ $KONG_PACKAGE_NAME == "kong" ]]; then
        IS_ENTERPRISE=0
    fi

    if [[ $DISTRO == "Ubuntu" ]]; then
        os_install_ubuntu
    else
        echo "Unsupported OS: $DISTRO"
        exit 1
    fi

    # ==================================================
    # Platform independent config
    # ==================================================

    # Generate passwords
    POSTGRES_PASSWORD=$(echo $RANDOM | md5sum | head -c 20)
    ADMIN_PASSWORD=$(echo $RANDOM | md5sum | head -c 20)

    # Configure Postgres
    DB_EXISTS=$(sudo su - postgres -c "psql -lqt" | cut -d \| -f 1 | grep -w kong | wc -l) || true
    if [[ $DB_EXISTS == 0 ]]; then
        sudo su - postgres -c "psql -c \"CREATE USER kong WITH PASSWORD '$POSTGRES_PASSWORD';\" > /dev/null";
        sudo su - postgres -c "psql -c \"CREATE DATABASE kong OWNER kong\" > /dev/null";
    fi

    # Configure Kong
    echo "Running Kong migrations"
    sudo cp /etc/kong/kong.conf.default /etc/kong/kong.conf
    sudo sed -i "s/#pg_password =/pg_password = $POSTGRES_PASSWORD/" /etc/kong/kong.conf
    KONG_PASSWORD=$ADMIN_PASSWORD sudo -E env "PATH=$PATH" kong migrations bootstrap > /dev/null  2>&1

    echo "Starting Kong"
    sudo env "PATH=$PATH" kong start > /dev/null 2>&1

    # Output success
    echo
    echo "==================================================="
    echo "Kong Gateway is now running on your system"
    echo "Ensure that port 8000 is open to the public"
    if [[ $IS_ENTERPRISE -gt 0 ]]; then
    echo
    echo "Kong Manager is available on port 8002"
    echo "See https://docs.konghq.com/gateway/latest/kong-manager/enable/ to enable the UI"
    echo "You can log in with the username 'kong_admin' and password '$ADMIN_PASSWORD'"
    fi
    echo "==================================================="
} 

  while getopts "p:v:" o; do
    case "${o}" in
        p)
            KONG_PACKAGE_NAME=${OPTARG}
            ;;
        v)
            KONG_PACKAGE_VERSION=${OPTARG}
            ;;
    esac
done

echo "This script will install Kong Gateway in traditional mode, where it acts as both the Control Plane and Data Plane. Running in this mode may have a small performance impact."
echo
echo "Would you prefer to have Kong host your Control Plane, allowing your data plane to run at maximum performance and decreasing your deployment complexity?"
echo
while true; do
    read -p "Switch to using Konnect? (y/n) " yn
    case $yn in
        [Yy]* ) echo; echo "Head over to https://get.konghq.com/konnect/ubuntu to get started"; break;;
        [Nn]* ) run_os_install; break;;
        * ) echo "Please answer yes or no.";;
    esac
done
