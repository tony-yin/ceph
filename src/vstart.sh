#!/bin/sh

[ "$CEPH_NUM_MON" = "" ] && CEPH_NUM_MON=3
[ "$CEPH_NUM_OSD" = "" ] && CEPH_NUM_OSD=1
[ "$CEPH_NUM_MDS" = "" ] && CEPH_NUM_MDS=1

new=0
debug=0
start_all=1
start_mon=0
start_mds=0
start_osd=0
localhost=0
nodaemon=0
MON_ADDR=""

conf="ceph.conf"

usage="usage: $0 [option]... [mon] [mds] [osd]\n"
usage=$usage"options:\n"
usage=$usage"\t-d, --debug\n"
usage=$usage"\t-n, --new\n"
usage=$usage"\t--valgrind[_{osd,mds,mon}] 'toolname args...'\n"
usage=$usage"\t-m ip:port\t\tspecify monitor address\n"

usage_exit() {
	printf "$usage"
	exit
}

while [ $# -ge 1 ]; do
case $1 in
    -d | --debug )
	    debug=1
	    ;;
    -l | --localhost )
	    localhost=1
	    ;;
    --new | -n )
	    new=1
	    ;;
    --valgrind )
	    [ "$2" = "" ] && usage_exit
	    valgrind=$2
	    shift
	    ;;
    --valgrind_mds )
	    [ "$2" = "" ] && usage_exit
	    valgrind_mds=$2
	    shift
	    ;;
    --valgrind_osd )
	    [ "$2" = "" ] && usage_exit
	    valgrind_osd=$2
	    shift
	    ;;
    --valgrind_mon )
	    [ "$2" = "" ] && usage_exit
	    valgrind_mon=$2
	    shift
	    ;;
    --nodaemon )
	    nodaemon=1
	    ;;
    mon | cmon )
	    start_mon=1
	    start_all=0
	    ;;
    mds | cmds )
	    start_mds=1
	    start_all=0
	    ;;
    osd | cosd )
	    start_osd=1
	    start_all=0
	    ;;
    -m )
	    [ "$2" = "" ] && usage_exit
	    MON_ADDR=$2
	    shift
	    ;;
    * )
	    usage_exit
esac
shift
done

if [ "$start_all" -eq 1 ]; then
	start_mon=1
	start_mds=1
	start_osd=1
fi

ARGS="-c $conf"

run() {
    type=$1
    shift
    eval "valg=\$valgrind_$type"
    [ -z "$valg" ] && valg="$valgrind"

    if [ -n "$valg" ]; then
	echo "valgrind --tool=$valg $* -f &"
	valgrind --tool=$valg $* -f &
	sleep 1
    else
	if [ "$nodaemon" -eq 0 ]; then
	    echo "$*"
	    $*
	else
	    echo "crun $* -f &"
	    ./crun $* -f &
	fi
    fi
}

if [ "$debug" -eq 0 ]; then
    CMONDEBUG='
	debug mon = 10
        debug ms = 1'
    COSDDEBUG='
        debug ms = 1'
    CMDSDEBUG='
        debug ms = 1'
else
    echo "** going verbose **"
    CMONDEBUG='
        lockdep = 1
	debug mon = 20
        debug paxos = 20
        debug ms = 1'
    COSDDEBUG='
        lockdep = 1
        debug ms = 1
        debug osd = 25
        debug journal = 20
        debug filestore = 10'
    CMDSDEBUG='
        lockdep = 1
        debug ms = 1
        debug mds = 20
        mds log max segments = 2'
fi

if [ "$MON_ADDR" != "" ]; then
	CMON_ARGS=" -m "$MON_ADDR
	COSD_ARGS=" -m "$MON_ADDR
	CMDS_ARGS=" -m "$MON_ADDR
fi


# lockdep everywhere?
# export CEPH_ARGS="--lockdep 1"


# sudo if btrfs
test -d dev/osd0/. && test -e dev/sudo && SUDO="sudo"

if [ "$start_all" -eq 1 ]; then
	$SUDO ./stop.sh
fi
$SUDO rm -f core*

test -d out || mkdir out
$SUDO rm -f out/*
test -d log && rm -f log/*
test -d gmon && $SUDO rm -rf gmon/*


# figure machine's ip
if [ "$localhost" -eq 1 ]; then
    IP="127.0.0.1"
else
    HOSTNAME=`hostname`
    echo hostname $HOSTNAME
    IP=`host $HOSTNAME | grep 'has address' | cut -d ' ' -f 4`
fi
echo "ip $IP"

[ "$CEPH_BIN" = "" ] && CEPH_BIN=.
[ "$CEPH_PORT" = "" ] && CEPH_PORT=6789

if [ "$start_mon" -eq 1 ]; then
	if [ "$new" -eq 1 ]; then
	# build and inject an initial osd map
		$CEPH_BIN/osdmaptool --clobber --createsimple 4 .ceph_osdmap --pg_bits 2
	fi

	if [ "$new" -eq 1 ]; then
	        cat <<EOF > $conf
; generated by vstart.sh on `date`
[global]
	log dir = out
	logger dir = log
	chdir = ""
	pid file = out/\$type\$id.pid
[mds]
	pid file = out/\$name.pid
$CMDSDEBUG
[osd]
$COSDDEBUG
[mon]
$CMONDEBUG

[group everyone]
	addr = 0.0.0.0/0

[mount /]
	allow = %everyone
EOF
		if [ `echo $IP | grep '^127\\.'` ]
		then
			echo
			echo "WARNING: hostname resolves to loopback; remote hosts will not be able to"
			echo "  connect.  either adjust /etc/hosts, or edit this script to use your"
			echo "  machine's real IP."
			echo
		fi

            	$SUDO $CEPH_BIN/authtool --gen-key --name=client.admin monkeys.bin

		# build a fresh fs monmap, mon fs
		# $CEPH_BIN/monmaptool --create --clobber --print .ceph_monmap
		str="$CEPH_BIN/monmaptool --create --clobber"
		for f in `seq 0 $((CEPH_NUM_MON-1))`
		do
			str=$str" --add $IP:$(($CEPH_PORT+$f))"
			cat <<EOF >> $conf
[mon$f]
        mon data = "dev/mon$f"
        mon addr = $IP:$(($CEPH_PORT+$f))
        keys file = dev/mon$f/monkeys.bin
EOF
		done
		str=$str" --print .ceph_monmap"
		echo $str
		$str

		for f in `seq 0 $((CEPH_NUM_MON-1))`
		do
		    echo $CEPH_BIN/mkmonfs --clobber --mon-data dev/mon$f -i $f --monmap .ceph_monmap --osdmap .ceph_osdmap
		    key_fn=monkeys.bin
		    $CEPH_BIN/mkmonfs -c $conf --clobber --mon-data=dev/mon$f -i $f --monmap=.ceph_monmap --osdmap=.ceph_osdmap --keys-file=$key_fn
		done
	fi

	# start monitors
	if [ "$start_mon" -ne 0 ]; then
		for f in `seq 0 $((CEPH_NUM_MON-1))`; do
		    run 'mon' $CEPH_BIN/cmon -i $f $ARGS $CMON_ARGS
		done
		sleep 1
	fi
fi

#osd
if [ "$start_osd" -eq 1 ]; then
    for osd in `seq 0 $((CEPH_NUM_OSD-1))`
    do
	if [ "$new" -eq 1 ]; then
	    cat <<EOF >> $conf
[osd$osd]
        osd data = dev/osd$osd
        osd journal = dev/osd$osd/journal
        osd journal size = 100
        keys file = dev/osd$osd/osd$osd.keys.bin
EOF
	    echo mkfs osd$osd
	    echo $SUDO $CEPH_BIN/cosd -i $osd $ARGS --mkfs # --debug_journal 20 --debug_osd 20 --debug_filestore 20 --debug_ebofs 20
	    $SUDO $CEPH_BIN/cosd -i $osd $ARGS --mkfs # --debug_journal 20 --debug_osd 20 --debug_filestore 20 --debug_ebofs 20
	    key_fn=dev/osd$osd/osd$osd.keys.bin
            $SUDO $CEPH_BIN/authtool --gen-key $key_fn
            $SUDO $CEPH_BIN/ceph -i $key_fn auth add osd.$osd
	fi
	echo start osd$osd
	run 'osd' $SUDO $CEPH_BIN/cosd -i $osd $ARGS $COSD_ARGS
    done
fi

# mds
if [ "$start_mds" -eq 1 ]; then
    mds=0
    for name in a b c d e f g h i j k l m n o p
    do
        key_fn=dev/mds_$name.keys.bin
	if [ "$new" -eq 1 ]; then
	    cat <<EOF >> $conf
[mds.$name]
        keys file = $key_fn
EOF
            $SUDO $CEPH_BIN/authtool --gen-key $key_fn
            $SUDO $CEPH_BIN/ceph -i $key_fn auth add mds.$name
	fi
	
	run 'mds' $CEPH_BIN/cmds -i $name $ARGS $CMDS_ARGS
	
	mds=$(($mds + 1))
	[ $mds -eq $CEPH_NUM_MDS ] && break

#valgrind --tool=massif $CEPH_BIN/cmds $ARGS --mds_log_max_segments 2 --mds_thrash_fragments 0 --mds_thrash_exports 0 > m  #--debug_ms 20
#$CEPH_BIN/cmds -d $ARGS --mds_thrash_fragments 0 --mds_thrash_exports 0 #--debug_ms 20
#$CEPH_BIN/ceph mds set_max_mds 2
    done
    echo $CEPH_BIN/ceph mds set_max_mds $CEPH_NUM_MDS
    $CEPH_BIN/ceph mds set_max_mds $CEPH_NUM_MDS
fi

echo "started.  stop.sh to stop.  see out/* (e.g. 'tail -f out/????') for debug output."

