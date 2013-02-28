#!/bin/sh
#
# Copyright (C) 2013 Oracle. GPL v2.
# Author: Dwight Engen <dwight.engen@oracle.com>
#
# Test script to install/boot/destroy all Oracle Linux releases.
# Each release is installed in an LXC container and booted. An expect script
# is then used to login to the container, verify the rpm database, and test
# the network by ping www.oracle.com. After this the container is stopped
# and destroyed.
#
# Assumes the expect script is in /root, and containers are in /container
#
MIRRORURL="ftp://delphi/Oracle-Public-Yum"
ARCHS="i386"
OL4_RELEASES="4.6 4.7 4.8 4.9 4.latest"
OL5_RELEASES="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.latest"
OL6_RELEASES="6.0 6.2 6.3 6.latest"
ALL_RELEASES="$OL4_RELEASES $OL5_RELEASES $OL6_RELEASES"
#RELEASES="$OL4_RELEASES"
#RELEASES="$OL5_RELEASES"
#RELEASES="$OL6_RELEASES"
RELEASES="$ALL_RELEASES"

becho()
{
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo
}

strip_escapes()
{
    sed -r -i -e 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K|G]//g' $1
    sed -r -i -e 's/\x1Bc//g' $1
    sed -r -i -e 's/\x0D//g' $1
}

for arch in $ARCHS
do
    for release in $RELEASES
    do
        ctname="OL-$arch-$release"
        becho "Creating container $ctname ..."
        lxc-create -n $ctname -t oracle -- -a $arch -R $release -u $MIRRORURL \
                   |tee /container/$ctname.install

        becho "Starting container $ctname ..."
        lxc-start -d -n $ctname -L /container/$ctname-con.log

        # becho "This is your chance to do some interactive testing with lxc-console. Ctrl-a-q to quit"
	# read
        # lxc-console -n $ctname
        becho "Logging in and test container $ctname ..."
        sleep 1
        expect /root/lxc-ol-install.exp $ctname |tee /container/$ctname-exp.log
        strip_escapes /container/$ctname-exp.log

        becho "Shutdown container $ctname ..."
        # lxc-shutdown is nicer, but lxc-stop is quicker, and we're going to
        # lxc-destroy the container anyways
        # lxc-shutdown -w -n $ctname
        lxc-stop -n $ctname

        becho "Destroying container $ctname ..."
        lxc-destroy -n $ctname

        # strip escape sequences from console log
        strip_escapes /container/$ctname-con.log
    done
done
