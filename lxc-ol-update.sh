#!/bin/sh
#
# Copyright (C) 2014 Oracle. GPL v2.
# Author: Dwight Engen <dwight.engen@oracle.com>
#
# Test script to install Oracle Linux release and then yum update it,
# testing the lxc-patch yum plugin and template patching paths. Two
# upgrade scenarios are tested: from each point release to latest,
# and a rolling upgrade from each point release to the next.
#
# Assumes containers are in /container
#

MIRRORURL="http://delphi/Oracle-Public-Yum"
HOSTSADD="192.168.1.3 delphi"

# Set which arch you want to install
ARCHS="x86_64"
OL_x86_64_MAJOR_RELEASES="4 5"

OL4_LATEST="el4_latest"
OL4_x86_64_TOLATEST="4.6 4.7 4.8 4.9"

OL5_LATEST="el5_latest"
OL5_x86_64_TOLATEST="5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10"
#OL5_x86_64_TOLATEST="5.8 5.9 5.10"

OL6_LATEST="ol6_latest"
OL6_x86_64_TOLATEST="6.0 6.1 6.2 6.3 6.4 6.5"

OL5_x86_64_UPREPO="el5_u1_base el5_u2_base el5_u3_base el5_u4_base el5_u5_base ol5_u6_base ol5_u7_base ol5_u8_base ol5_u9_base ol5_u10_base el5_latest"
OL6_x86_64_UPREPO="ol6_u1_base ol6_u2_base ol6_u3_base ol6_u4_base ol6_u5_base ol6_latest"

becho()
{
    echo
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo
}

strip_escapes()
{
    sed -r -i -e 's/\x0D//g' $1
    sed -r -i -e 's/\x1Bc//g' $1
    sed -r -i -e 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K|G]//g' $1
}

container_start()
{
    becho "Starting container $1 $2 ..."
    lxc-start -d -n $1 -L /container/$1-con.log
    lxc-wait -n $1 -s RUNNING
}

container_wait_for_ip()
{
    # wait for container to obtain an IP address
    for try in `seq 1 20`; do
        CONTAINER_IP=`lxc-info -i -n $1 | awk '{ print $2 }'`
        if [ x"$CONTAINER_IP" != x ]; then
            break
        fi
        sleep 1
    done
}

container_update()
{
    becho "Updating $1 to $2..." |tee -a /container/$1-update.log
    sed -i "/\[$2\]/,/\[/ s/enabled=0/enabled=1/" /container/$1/rootfs/etc/yum.repos.d/public-yum*.repo
    lxc-attach -n $1 -- yum -y update 2>&1 >>/container/$1-update.log

    grep -q '' /container/$1-update.log
    if [ $? -eq 0 ]; then
        echo "Container patch check..."
    fi

    grep -q 'Patching container rootfs' /container/$1-update.log
    if [ $? -eq 0 ]; then
        echo "Container patched"
    fi
}

container_stop()
{
    becho "Shutdown container $1 $2 ..."
    #lxc-stop -t 120 -n $1
    lxc-stop -n $1
    lxc-wait -n $1 -s STOPPED
    strip_escapes /container/$1-con.log
}

container_destroy()
{
    becho "Destroying container $1 ..."
    lxc-destroy -n $1
}

for arch in $ARCHS
do
    # From each point release to latest
    for major in $(eval echo "\$OL_"$arch"_MAJOR_RELEASES")
    do
        for release in $(eval echo "\$OL"$major"_"$arch"_TOLATEST")
        do
            ctname="OL-$arch-$release"
            becho "Creating container $ctname ..."
            lxc-create -n $ctname -t oracle -- -a $arch -R $release -u $MIRRORURL \
                       |tee /container/$ctname.install
            strip_escapes /container/$ctname.install
            echo "$HOSTSADD" >>/container/$ctname/rootfs/etc/hosts
            container_start       $ctname ""
            container_wait_for_ip $ctname
            container_update      $ctname $(eval echo "\$OL"$major"_LATEST")
            container_stop        $ctname ""

            becho "Restarting container after update" >>/container/$ctname-con.log
            container_start       $ctname ""
            container_wait_for_ip $ctname
            container_stop        $ctname ""

            container_destroy $ctname
        done
    done

    # Rolling upgrade to each point release
#    for major in $(eval echo "\$OL_"$arch"_MAJOR_RELEASES")
#    do
#        ctname="OL-$arch-$major.x"
#        becho "Creating container $ctname ..."
#        lxc-create -n $ctname -t oracle -- -a $arch -R $major.0 -u $MIRRORURL \
#                   |tee /container/$ctname.install
#        strip_escapes /container/$ctname.install
#        echo "$HOSTSADD" >>/container/$ctname/rootfs/etc/hosts
#
#        for uprepo in $(eval echo "\$OL"$major"_"$arch"_UPREPO")
#        do
#            container_start       $ctname $uprepo
#            container_wait_for_ip $ctname
#            container_update      $ctname $uprepo
#            container_stop        $ctname $uprepo
#        done
#        container_destroy $ctname
#    done
done

echo "Installed      : `ls *.install |wc -l`"
echo "Patch checked  : `grep 'lxc-patch: checking if updated pkgs need patching' *update.log |wc -l`"
echo "Patched        : `grep 'Patching container rootfs' *update.log | wc -l`"
