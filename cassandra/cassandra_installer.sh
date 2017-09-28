#!/bin/sh

setup_base_group()
{
    TYPE_LOWER="$1"
    TYPE_UPPER="$2"

    echo
    echo "Configuring $TYPE_UPPER"

    echo -n "group_name: [$TYPE_LOWER] "
    while true; do
        read GROUP_NAME
        if [ -z "$GROUP_NAME" ]; then
            GROUP_NAME="$TYPE_LOWER"
        fi

        METRIC_GROUP_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$GROUP_NAME" $API_HOST/v2/revealmetrics/validate_metric_group_name?service=$SERVICE)

        if [ "$METRIC_GROUP_NAME_VALID" == "invalid" ]; then
            echo -n "This metric group name is already in use for a different service. Enter a different name:"
        else
            GROUP_LABEL="$GROUP_NAME"
            GROUP_NAME="$METRIC_GROUP_NAME_VALID"
            break
        fi
    done

    echo -n "dashboard: [$TYPE_UPPER] "
    while true; do
        read DASHBOARD
        if [ -z "$DASHBOARD" ]; then
            DASHBOARD="$TYPE_UPPER"
        fi

        DASHBOARD_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$DASHBOARD" $API_HOST/v2/revealmetrics/validate_dashboard_name?service=$SERVICE)

        if [ "$DASHBOARD_NAME_VALID" == "invalid" ]; then
            echo -n "This dashboard name is already in use for a different service. Enter a different name:"
        else
            break
        fi
    done

    echo "$TYPE_LOWER:" >> $CONFIG_FILE
    echo "  group_name: \"$GROUP_NAME\"" >> $CONFIG_FILE
    echo "  group_label: \"$GROUP_LABEL\"" >> $CONFIG_FILE
    echo "  dashboard: \"$DASHBOARD\"" >> $CONFIG_FILE
    echo "  clusters:" >> $CONFIG_FILE
    echo "Note: Group Label is same as group name which can be changed from UI"
}

setup_cassandra()
{
    DEFAULT_LABEL="$1"
    DEFAULT_URL="$2"
    DEFAULT_PORT="$3"

    echo -n "Unique_id: [$DEFAULT_LABEL] "
    read LABEL
    if [ -z "$LABEL" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "Unique_id cannot be blank"
            return 1
        fi
        LABEL="$DEFAULT_LABEL"
    fi

    echo "Server URL: [$DEFAULT_URL] "
    echo -n "Hint : Don't include http:// or https:// in the beginning. Mention the Route to your server."
    read URL
    if [ -z "$URL" ]; then
        if [ -z "$DEFAULT_URL" ]; then
            echo "Hostname cannot be blank"
            return 1
        fi
        URL="$DEFAULT_URL"
    fi

    echo -n "Port JMX(remote): [7199]"
    read PORT
    if [ -z "$PORT" ]; then
        PORT="$DEFAULT_PORT"
    fi

    echo -n "Username: "
    read USER_NAME

    echo -n "Password: "
    read PASSWORD

    echo
    if [ -z $USER_NAME ]; then
        echo "nodetool -h $URL -p $PORT status > /tmp/cassandra_stats.txt"
        nodetool -h $URL -p $PORT status > /tmp/cassandra_stats.txt
    else
        echo "nodetool -h $URL -p $PORT -u $USER_NAME -pw $PASSWORD status > /tmp/cassandra_stats.txt"
        nodetool -h $URL -p $PORT -u $USER_NAME -pw $PASSWORD status > /tmp/cassandra_stats.txt
    fi

    # check exit status of last command
    if [ -z "`grep -E 'U[N|L|M|J]' /tmp/cassandra_stats.txt`" ]; then
        echo
        echo "WARNING: Could not connect to Cassandra Cluster with $URL, "
        echo "  username $USER_NAME, password $PASSWORD, host $URL and port $PORT."
        echo "  If you keep this setting, you can edit it later in the config file:"
        echo "  $CONFIG_FILE"
        echo -n "  Keep setting and use this server anyway? [Yn]"
        read yn
        if [ -n "`echo $yn | egrep -io '^n'`" ]; then
            # just return 1, loop will re-run
            return 1
        fi
        echo

    else
        echo "SUCCESS!"
        echo
    fi

    echo "  -" >> $CONFIG_FILE
    echo "    name: \"$LABEL\""   >> $CONFIG_FILE
    echo "    hostname: \"$URL\"" >> $CONFIG_FILE
    echo "    port: \"$PORT\""    >> $CONFIG_FILE
    if [ -z $USER_NAME ]; then
        echo "    username:"      >> $CONFIG_FILE
        echo "    password:"      >> $CONFIG_FILE
    else
        echo "    username: \"$USER_NAME\""      >> $CONFIG_FILE
        echo "    password: \"$PASSWORD\""       >> $CONFIG_FILE
    fi
}


setup_upstart_init()
{
    INIT_FILE="/etc/init/revealmetrics_cassandra.conf"
    if [ -e "$INIT_FILE" ]; then
        stop `basename $INIT_FILE .conf` >/dev/null 2>&1
        rm $INIT_FILE
    fi

    # Make sure it's dead, Jim
    RBFILE="`basename $AGENT_FILE`"
    YMLFILE="`basename $CONFIG_FILE`"
    kill `ps aux | grep $RBFILE | grep $YMLFILE | awk '{print $2}'` >/dev/null 2>&1


    if [ -z "$CREATED_INIT" ]; then
        echo -n "Create upstart init file for agent? [Yn] "
        read yn
        if [ -z "`echo $yn | egrep -io '^n'`" ]; then
            CREATED_INIT="yes"
            echo -n "log file: [/usr/local/copperegg/log/cassandra_metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/copperegg/log/cassandra_metrics.log"
            fi
            mkdir -p `dirname $LOGFILE`
            touch $LOGFILE
            chown $COPPEREGG_USER:$COPPEREGG_GROUP `dirname $LOGFILE`
            chown $COPPEREGG_USER:$COPPEREGG_GROUP $LOGFILE

            API_SETTING=""
            if [ "$API_HOST" != "api.copperegg.com" ]; then
                # only set this var if it's non-default
                if [ -z "`echo $API_HOST | egrep '^http'`" ]; then
                    API_HOST="$PROTO://$API_HOST"
                fi
                API_SETTING="--apihost $API_HOST"
            fi

            EXE_FILE=`create_exe_file`

            chmod +x $EXE_FILE

            DEBUG_SETTING=""
            if [ -n "$DEBUG" ]; then
                DEBUG_SETTING="--debug"
            fi

            cat <<ENDINIT > $INIT_FILE
# Upstart file $INIT_FILE

kill timeout 5
respawn
respawn limit 5 30

start on runlevel [2345]
stop on runlevel [06]

exec su -s /bin/sh -c 'exec "\$0" "\$@"' $COPPEREGG_USER -- $EXE_FILE --config $CONFIG_FILE $API_SETTING $DEBUG_SETTING >> $LOGFILE 2>&1

ENDINIT

            echo
            echo "Upstart file $INIT_FILE created."
        fi
    fi

    if [ -n "$CREATED_INIT" ]; then
        echo
        echo "Thank you for setting up the Uptime Cloud Monitor Metrics Agent."
        echo "You may use 'sudo [start|stop] `basename $INIT_FILE .conf` to start/stop the agent"
        echo
        start `basename $INIT_FILE .conf`
        echo
    fi
}

setup_standard_init()
{
    /etc/init.d/copperegg-agent stop >/dev/null 2>&1 # old-named init file.
    rm -f /etc/init.d/copperegg-agent                # just blast it away.

    INIT_FILE="/etc/init.d/revealmetrics_cassandra"
    if [ -e "$INIT_FILE" ]; then
        $INIT_FILE stop >/dev/null 2>&1
        rm $INIT_FILE
    fi

    # Make sure it's dead, Jim
    RBFILE="`basename $AGENT_FILE`"
    YMLFILE="`basename $CONFIG_FILE`"
    kill `ps aux | grep $RBFILE | grep $YMLFILE | awk '{print $2}'` >/dev/null 2>&1

    if [ -z "$CREATED_INIT" ]; then
        echo -n "Create init file for agent? [Yn] "
        read yn
        if [ -z "`echo $yn | egrep -io '^n'`" ]; then
            CREATED_INIT="yes"
            echo -n "log file: [/usr/local/copperegg/log/revealmetrics_cassandra.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/copperegg/log/revealmetrics_cassandra.log"
            fi
            mkdir -p `dirname $LOGFILE`
            touch $LOGFILE
            chown $COPPEREGG_USER:$COPPEREGG_GROUP `dirname $LOGFILE`
            chown $COPPEREGG_USER:$COPPEREGG_GROUP $LOGFILE

            API_SETTING=""
            if [ "$API_HOST" != "api.copperegg.com" ]; then
                # only set this var if it's non-default
                if [ -z "`echo $API_HOST | egrep '^http'`" ]; then
                    API_HOST="$PROTO://$API_HOST"
                fi
                API_SETTING="--apihost $API_HOST"
            fi

            DEBUG_SETTING=""
            if [ -n "$DEBUG" ]; then
                DEBUG_SETTING="--debug"
            fi

            EXE_FILE=`create_exe_file`

            cat <<ENDINIT > $INIT_FILE
#!/bin/sh
### BEGIN INIT INFO
# Provides:           ucm-metrics
# Required-Start:     \$syslog
# Required-Stop:      \$syslog
# Default-Start:      2 3 4 5
# Default-Stop:       0 1 6
# Short-Description:  analytics collection for Uptime Cloud Monitor Custom Metrics
# Description:        <support-uptimecm@idera.com>
#
### END INIT INFO

# Author: Uptime Cloud Monitor <support-uptimecm@idera.com>
#

PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
RUBY_DAEMON=$AGENT_FILE
DAEMON=$EXE_FILE
CONFIGFILE=$CONFIG_FILE
LOGFILE=$LOGFILE
COPPEREGG_USER=$COPPEREGG_USER
DESC="custom analytics collection for Uptime Cloud Monitor"
NAME=revealmetrics_cassandra

do_start()
{
    su \$COPPEREGG_USER -s /bin/sh -c "nohup \$DAEMON --config \$CONFIGFILE $API_SETTING $DEBUG_SETTING >> \$LOGFILE 2>&1 &"
}

do_stop()
{
    PIDS="\`ps aux|grep \$DAEMON | grep \$CONFIGFILE | awk '{print \$2}'\`"
    if [ "\$PIDS" != "" ]; then
        kill \$PIDS
    else
        echo "ERROR: process not running"
    fi
}

do_status()
{
    ps aux|grep \$DAEMON | grep \$CONFIGFILE >/dev/null 2>&1
}

case "\$1" in
    start)
        [ "\$VERBOSE" != no ] && echo -n "Starting \$DESC: \$NAME"
        do_start
        case "\$?" in
            0|1) [ "\$VERBOSE" != no ] && echo 0 ;;
            2) [ "\$VERBOSE" != no ] && echo 1 ;;
        esac
    ;;
    stop)
        [ "\$VERBOSE" != no ] && echo -n "Stopping \$DESC: \$NAME"
        do_stop
        case "\$?" in
            0|1) [ "\$VERBOSE" != no ] && echo 0 ;;
            2) [ "\$VERBOSE" != no ] && echo 1 ;;
        esac
    ;;
    status)
        do_status && exit 0 || exit \$?
    ;;
esac

exit \$?

ENDINIT

        fi
    fi

    if [ -n "$CREATED_INIT" ]; then
        chmod 755 $INIT_FILE

        if [ -d "/etc/rc1.d" ]; then
            rm -f /etc/rc*.d/*revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc0.d/K99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc1.d/K99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc2.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc3.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc4.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc5.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/rc6.d/K99revealmetrics_cassandra
        elif [ -d "/etc/init.d/rc1.d" ]; then
            rm -f /etc/init.d/rc*.d/*revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc1.d/K99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc2.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc3.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc4.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc5.d/S99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rc6.d/K99revealmetrics_cassandra
            ln -s $INIT_FILE /etc/init.d/rcS.d/S99revealmetrics_cassandra
        fi

        echo
        echo "Thank you for setting up the Uptime Cloud Monitor Metrics Agent."
        echo "You may use 'sudo $INIT_FILE [start|stop]' to start/stop the agent"
        echo
        $INIT_FILE start
        echo
    fi
}

create_exe_file()
{
    LAUNCHER_FILE="/usr/local/copperegg/ucm-metrics/revealmetrics_cassandra_launcher.sh"
    if [ -n "$RVM_SCRIPT" ]; then
        cat <<ENDINIT > $LAUNCHER_FILE
#!/bin/bash
DIRNAME="/usr/local/copperegg/ucm-metrics/cassandra"
. $RVM_SCRIPT
$AGENT_FILE \$*
ENDINIT
        EXE_FILE=$LAUNCHER_FILE
    elif [ -n "$RUBY_PATH" ]; then
        cat <<ENDINIT > $LAUNCHER_FILE
#!/bin/sh
PATH=$RUBY_PATH:\$PATH
export PATH
$AGENT_FILE \$*
ENDINIT
        EXE_FILE=$LAUNCHER_FILE
    else
        # no launcher needed; using system ruby which installed properly.  we hope.
        EXE_FILE=$AGENT_FILE
    fi
    chmod +x $EXE_FILE
    echo $EXE_FILE
}

create_init_file() {
    CREATED_INIT=""

    # Detect Upstart system, If it exists proceed with Upstart init file

    READLINK_UPSTART=`readlink /sbin/init | grep -i 'upstart'`
    DPKG_UPSTART=""
    RPM_UPSTART=""
    PACMAN_UPSTART=""

    if [ -n "`which dpkg 2>/dev/null`" ]; then
        DPKG_UPSTART=`dpkg -S /sbin/init | grep -i 'upstart'`
    fi

    if [ -n "`which rpm 2>/dev/null`" ]; then
        RPM_UPSTART=`rpm -qf /sbin/init | grep -i 'upstart'`
    fi

    if [ -n "`which pacman 2>/dev/null`" ]; then
        PACMAN_UPSTART=`pacman -Qo /sbin/init | grep -i 'upstart'`
    fi

    if [ -n "$READLINK_UPSTART" -o -n "$DPKG_UPSTART" -o -n "$RPM_UPSTART" -o -n "$PACMAN_UPSTART" ]; then
        if [ -d '/etc/init' ]; then
            setup_upstart_init
        else
            echo "Upstart Init system detected but /etc/init does not exist. Creating a SYS-V Init script instead."
        fi
    fi

    if [ -d '/etc/init.d' -a -z "$CREATED_INIT" ]; then
        setup_standard_init
    fi

    if [ -z "$CREATED_INIT" ]; then
        echo
        echo "Thank you for setting up the Uptime Cloud Monitor Metrics Agent."
        echo "You may run it using the following command:"
        echo "nohup ruby $AGENT_FILE --config $CONFIG_FILE >/tmp/revealmetrics_couchdb.log 2>&1 &"
        echo
    fi
}

###############################################################
###############################################################
##   End Functions, start main code
###############################################################
###############################################################

if [ -z "$FREQ" -o -z "`echo $FREQ | egrep -o '^[0-9]$'`" ]; then
    # FREQ is an empty string or not a number.  Ask for it
    echo
    echo "Monitoring frequency (sample rate) can be one sample per: 15, 60, 300, 900, 3600 seconds."
    echo -n "What frequency would you like? [60] "
    read FREQ
    if [ -z "`echo $FREQ | egrep -o '^[0-9]+$'`" ]; then
        # freq is not a number. default to 60
        FREQ=60
    elif [ $FREQ -le 15 ]; then
        FREQ=15
    elif [ $FREQ -le 60 ]; then
        FREQ=60
    elif [ $FREQ -le 300 ]; then
        FREQ=300
    elif [ $FREQ -le 900 ]; then
        FREQ=900
    else
        FREQ=3600
    fi
fi
echo "Monitoring frequency set to one sample per $FREQ seconds."

echo

echo "Installing required gems "
echo "Installing gem bundler"
gem install bundler -v "1.12.5" >> $PKG_INST_OUT
install_rc=$?

if [ $install_rc -ne 0 ]; then
    echo
    echo "********************************************************"
    echo "*** "
    echo "*** WARNING: gem bundler did not install properly!"
    echo "*** Please contact support-uptimecm@idera.com if you are"
    echo "*** unable to run 'gem install bundler -v 1.12.5 ' manually."
    echo "*** "
    echo "********************************************************"
    echo
fi

OLDIFS=$IFS
IFS=$'\n'
gems=`grep -w gem cassandra/Gemfile | awk '{$1="" ; print $0}'`

for gem in $gems; do
  gem=${gem//[\'\" ]/}
  IFS=',' read -r -a array <<< "$gem"
  echo "Installing gem ${array[0]}"
  if [ -z "${array[1]}" ]
    then
    gem install --no-ri --no-rdoc ${array[0]} >> $PKG_INST_OUT
  else
    gem install --no-ri --no-rdoc ${array[0]} -v ${array[1]} >> $PKG_INST_OUT
  fi

  install_rc=$?
  if [ $install_rc -ne 0 ]; then
    echo
    echo "********************************************************"
    echo "*** "
    echo "*** WARNING: gem ${array[0]} did not install properly!"
    echo "*** Please contact support-uptimecm@idera.com if you are"
    if [ -z "${array[1]}" ]
      then
      echo "*** unable to run 'gem install ${array[0]}' manually."
    else
      echo "*** unable to run 'gem install ${array[0]} -v \"${array[1]}\"' manually."
    fi
    echo "*** "
    echo "********************************************************"
    echo
  fi
done
IFS=$OLDIFS


#
# create config.yml
#
echo
echo
echo "------------------------------------------------------------------"
echo

CONFIG_FILE="/usr/local/copperegg/ucm-metrics/cassandra/config.yml"
AGENT_FILE="/usr/local/copperegg/ucm-metrics/cassandra/cassandra.rb"

echo
echo "Creating config.yml."
echo

echo "copperegg:" > $CONFIG_FILE
echo "  apikey: \"$USER_API_KEY\"" >> $CONFIG_FILE
echo "  apihost: \"$API_HOST\"" >> $CONFIG_FILE
echo "  frequency: $FREQ" >> $CONFIG_FILE
echo "  services:" >> $CONFIG_FILE
echo "  - cassandra" >> $CONFIG_FILE


setup_base_group "cassandra" "Cassandra"
rc=1
while [ $rc -ne 0 ]; do
    # loop with defaults until they get it right
    echo "Configuring first Cassandra Cluster (required)"
    setup_cassandra "`hostname | sed 's/ /_/g'`-cassandra" "localhost" "7199"
    rc=$?
done

while true; do
    echo -n "Add another Cassandra server? [Yn] "
    read yn
    if [ -n "`echo $yn | egrep -io '^n'`" ]; then
        break
    fi
    setup_cassandra "" "" "7199"
done

chown -R $COPPEREGG_USER:$COPPEREGG_GROUP /usr/local/copperegg/ucm-metrics/*

echo
echo
echo "------------------------------------------------------------------"
echo
echo "Done creating config file $CONFIG_FILE"
echo

# Method to create init file, based on machine's Init system
create_init_file
