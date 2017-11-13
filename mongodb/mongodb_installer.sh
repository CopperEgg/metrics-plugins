#!/bin/bash

setup_admin_base_group()
{
    MONGO_ADMIN_GROUP="$1"
    MONGO_ADMIN_LABEL="$2"

    echo
    echo "Configuring MongoDB Admin Service"

    echo -n "Mongo Server Metrics Group Name: [$MONGO_ADMIN_GROUP] "
    while true; do
        read ADMIN_GROUP_NAME
        if [ -z "$ADMIN_GROUP_NAME" ]; then
            ADMIN_GROUP_NAME="$MONGO_ADMIN_GROUP"
        fi

        ADMIN_GROUP_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$ADMIN_GROUP_NAME" $API_HOST/v2/revealmetrics/validate_metric_group_name?service=$MONGO_ADMIN_GROUP)

        if [ "$ADMIN_GROUP_NAME_VALID" == "invalid" ]; then
            echo -n "This metric group name is already in use for a different service. Enter a different name:"
        else
            ADMIN_GROUP_NAME="$ADMIN_GROUP_NAME_VALID"
            ADMIN_GROUP_LABEL="$ADMIN_GROUP_NAME"
            break
        fi
    done

    echo -n "Mongo Server Metrics Dashboard: [$MONGO_ADMIN_LABEL] "
    while true; do
        read ADMIN_DASHBOARD
        if [ -z "$ADMIN_DASHBOARD" ]; then
            ADMIN_DASHBOARD="$MONGO_ADMIN_LABEL"
        fi

        ADMIN_DASHBOARD_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$ADMIN_DASHBOARD" $API_HOST/v2/revealmetrics/validate_dashboard_name?service=$MONGO_ADMIN_GROUP)

        if [ "$ADMIN_DASHBOARD_NAME_VALID" == "invalid" ]; then
            echo -n "This dashboard name is already in use for a different service. Enter a different name:"
        else
            break
        fi
    done

    sed -i "0,/MONGO-ADMIN-GROUP/s//$ADMIN_GROUP_NAME/" $CONFIG_FILE
    sed -i "0,/MONGO-ADMIN-GROUP-LABEL/s//$ADMIN_GROUP_LABEL/" $CONFIG_FILE
    sed -i "0,/MONGO-ADMIN-DASH/s//$ADMIN_DASHBOARD/" $CONFIG_FILE
    echo "Note: Group Label is same as group name which can be changed from UI"
}

setup_db_base_group()
{
    MONGO_DB_GROUP="$1"
    MONGO_DB_LABEL="$2"

    echo
    echo "Configuring MongoDB Database Service"

    echo -n "Mongo Server Metrics Group Name: [$MONGO_DB_GROUP] "
    while true; do
        read DB_GROUP_NAME
        if [ -z "$DB_GROUP_NAME" ]; then
            DB_GROUP_NAME="$MONGO_DB_GROUP"
        fi

        DB_GROUP_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$DB_GROUP_NAME" $API_HOST/v2/revealmetrics/validate_metric_group_name?service=$MONGO_DB_GROUP)

        if [ "$DB_GROUP_NAME_VALID" == "invalid" ]; then
            echo -n "This metric group name is already in use for a different service. Enter a different name:"
        else
            DB_GROUP_NAME="$DB_GROUP_NAME_VALID"
            DB_GROUP_LABEL="$DB_GROUP_NAME"
            break
        fi
    done

    echo -n "Mongo Server Metrics Dashboard: [$MONGO_DB_LABEL] "
    while true; do
        read DB_DASHBOARD
        if [ -z "$DB_DASHBOARD" ]; then
            DB_DASHBOARD="$MONGO_DB_LABEL"
        fi

        DB_DASHBOARD_NAME_VALID=$(curl -su $API_KEY:U -G --data-urlencode "name=$DB_DASHBOARD" $API_HOST/v2/revealmetrics/validate_dashboard_name?service=$MONGO_DB_GROUP)

        if [ "$DB_DASHBOARD_NAME_VALID" == "invalid" ]; then
            echo -n "This dashboard name is already in use for a different service. Enter a different name:"
        else
            break
        fi
    done

    sed -i "0,/MONGO-DB-GROUP/s//$DB_GROUP_NAME/" $CONFIG_FILE
    sed -i "0,/MONGO-DB-GROUP-LABEL/s//$DB_GROUP_LABEL/" $CONFIG_FILE
    sed -i "0,/MONGO-DB-DASH/s//$DB_DASHBOARD/" $CONFIG_FILE
    echo "Note: Group Label is same as group name which can be changed from UI"
}

setup_database()
{
    LABEL="$1"
    URL="$2"
    PORT="$3"
    INITIAL_CHECK="$4"

    echo -n "Database Name: "
    read DBNAME

    echo -n "Username: "
    read USER_NAME

    echo -n "Password: "
    read PASSWORD

    # Each database, user and authentication credentials configured by the customer is tested to verify it has the
    # privilege to access stats commands.
    echo "Testing connection with ruby script"
    echo "For testing MongoDB admin DB connection, '{serverStatus: 1}' command will be used."
    echo "For testing MongoDB normal DB connection, '{dbstats: 1}' command will be used."

    op=`ruby $MONGODB_TEST_SCRIPT $URL $PORT $DBNAME $INITIAL_CHECK $USER_NAME $PASSWORD`

    # check exit status of last command
    if [ $? -ne 0 -o "$op" == "error" ]; then
        echo
        echo "WARNING: Could not connect to MongoDB Server with $URL, "
        echo "  username $USER_NAME, password $PASSWORD and port $PORT."
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

    if [ "$INITIAL_CHECK" == "initial" ]; then
        ADMIN_BLOCK_NAME="  - name: \"$LABEL\""
        ADMIN_BLOCK_HOST="    hostname: \"$URL\""
        ADMIN_BLOCK_PORT="    port: $PORT"
        ADMIN_BLOCK_USER="    username: \"$USER_NAME\""
        ADMIN_BLOCK_PWD="    password: \"$PASSWORD\""
        ADMIN_BLOCK_DB_NAME="    database: \"$DBNAME\""

        ADMIN_DATA="$ADMIN_BLOCK_NAME\n$ADMIN_BLOCK_HOST\n$ADMIN_BLOCK_PORT\n$ADMIN_BLOCK_USER\n$ADMIN_BLOCK_PWD\n$ADMIN_BLOCK_DB_NAME"
        ADMIN_DATA="$ADMIN_DATA\n  - ANOTHER-ADMIN-SERVER"
        sed -i "0,/  - ANOTHER-ADMIN-SERVER/s//$ADMIN_DATA/" $CONFIG_FILE

        DB_BLOCK_START="    databases:"
        DB_BLOCK_NAME="    - name: \"$DBNAME\""
        DB_BLOCK_USER="      username: \"$USER_NAME\""
        DB_BLOCK_PWD="      password: \"$PASSWORD\""

        DB_DATA="$ADMIN_BLOCK_NAME\n$ADMIN_BLOCK_HOST\n$ADMIN_BLOCK_PORT\n$DB_BLOCK_START"
        DB_DATA="$DB_DATA\n    - ANOTHER-DB\n  - ANOTHER-DB-SERVER"
        sed -i "0,/  - ANOTHER-DB-SERVER/s//$DB_DATA/" $CONFIG_FILE

        DB_DATA="$DB_BLOCK_NAME\n$DB_BLOCK_USER\n$DB_BLOCK_PWD"
        DB_DATA="$DB_DATA\n    - ANOTHER-DB"
        sed -i "0,/    - ANOTHER-DB/s//$DB_DATA/" $CONFIG_FILE
    else

        DB_BLOCK_NAME="    - name: \"$DBNAME\""
        DB_BLOCK_USER="      username: \"$USER_NAME\""
        DB_BLOCK_PWD="      password: \"$PASSWORD\""

        DB_DATA="$DB_BLOCK_NAME\n$DB_BLOCK_USER\n$DB_BLOCK_PWD"
        DB_DATA="$DB_DATA\n    - ANOTHER-DB"
        sed -i "0,/    - ANOTHER-DB/s//$DB_DATA/" $CONFIG_FILE
    fi
}

setup_mongodb()
{
    sed -i "s/    - ANOTHER-DB//g" $CONFIG_FILE
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
    echo -n "Server URL : [$DEFAULT_URL] "
    read URL
    if [ -z "$URL" ]; then
        if [ -z "$DEFAULT_URL" ]; then
            echo "Hostname cannot be blank"
            return 1
        fi
        URL="$DEFAULT_URL"
    fi

    echo -n "Port: [27017]"
    read PORT
    if [ -z "$PORT" ]; then
        PORT="$DEFAULT_PORT"
    fi

    lc=1
    while [ $lc -ne 0 ]; do
      # loop with defaults until they get it right
      echo "Configuring first MongoDB admin Database (required)"
      echo "This database will be used to fetch Server metrics. Please ensure it has correct privilege access."
      echo "Refer to Readme for more details."
      setup_database $LABEL $URL $PORT "initial"
      lc=$?
    done

    while true; do
      echo -n "Add another Database for MongoDB server? [Yn] "
      read yn
      if [ -n "`echo $yn | egrep -io '^n'`" ]; then
        break
      fi
      setup_database $LABEL $URL $PORT ""
    done
}


setup_upstart_init()
{
    INIT_FILE="/etc/init/revealmetrics_mongodb.conf"
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
            echo -n "log file: [/usr/local/copperegg/log/mongodb_metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                    LOGFILE="/usr/local/copperegg/log/mongodb_metrics.log"
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

    INIT_FILE="/etc/init.d/revealmetrics_mongodb"
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
            echo -n "log file: [/usr/local/copperegg/log/revealmetrics_mongodb.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/copperegg/log/revealmetrics_mongodb.log"
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
NAME=revealmetrics_mongodb

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
            rm -f /etc/rc*.d/*revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc0.d/K99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc1.d/K99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc2.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc3.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc4.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc5.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/rc6.d/K99revealmetrics_mongodb
        elif [ -d "/etc/init.d/rc1.d" ]; then
            rm -f /etc/init.d/rc*.d/*revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc1.d/K99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc2.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc3.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc4.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc5.d/S99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rc6.d/K99revealmetrics_mongodb
            ln -s $INIT_FILE /etc/init.d/rcS.d/S99revealmetrics_mongodb
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
    LAUNCHER_FILE="/usr/local/copperegg/ucm-metrics/revealmetrics_mongodb_launcher.sh"
    if [ -n "$RVM_SCRIPT" ]; then
        cat <<ENDINIT > $LAUNCHER_FILE
#!/bin/bash
DIRNAME="/usr/local/copperegg/ucm-metrics/mongodb"
. $RVM_SCRIPT
cd \$DIRNAME
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

    if [ \( -n "$READLINK_UPSTART" -o -n "$DPKG_UPSTART" -o -n "$RPM_UPSTART" -o -n "$PACMAN_UPSTART" \) -a \( -d '/etc/init' \) ]; then
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
        echo "nohup ruby $AGENT_FILE --config $CONFIG_FILE >/tmp/revealmetrics_mongodb.log 2>&1 &"
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
gems=`grep -w gem mongodb/Gemfile | awk '{$1="" ; print $0}'`

for gem in $gems; do
  gem=${gem//[\'\" ]/}
  IFS=',' read -r -a array <<< "$gem"
  echo "Installing gem ${array[0]}"

  if [ -z "${array[1]}" ]; then
      is_gem_present=`gem query --name-matches "^${array[0]}$" --installed`
  else
      is_gem_present=`gem query --name-matches "^${array[0]}$" --installed --version ${array[1]}`
  fi

  if [[ "${is_gem_present}" == "true" ]]; then
      echo "  - Skipping gem installation as ${array[0]} is already installed"
      continue
  fi

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

CONFIG_FILE="/usr/local/copperegg/ucm-metrics/mongodb/config.yml"
AGENT_FILE="/usr/local/copperegg/ucm-metrics/mongodb/mongodb.rb"
MONGODB_TEST_SCRIPT="/usr/local/copperegg/ucm-metrics/mongodb/test_mongodb_connection.rb"
CONFIG_TEMPLATE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/config-template.yml"

echo
echo "Creating config.yml."
echo
cp $CONFIG_TEMPLATE $CONFIG_FILE

sed -i "s@API-KEY@$API_KEY@g" $CONFIG_FILE
sed -i "s@FREQUENCY@$FREQ@g" $CONFIG_FILE
sed -i "s@APIHOST@$API_HOST@g" $CONFIG_FILE

setup_admin_base_group "mongodb_admin" "MongoDB-Admin"
setup_db_base_group "mongodb" "MongoDB"

rc=1
while [ $rc -ne 0 ]; do
    # loop with defaults until they get it right
    echo "Configuring first MongoDB server (required)"
    setup_mongodb "`hostname | sed 's/ /_/g'`-mongodb" "localhost" "27017"
    rc=$?
done

while true; do
    echo -n "Add another MongoDB server? [Yn] "
    read yn
    if [ -n "`echo $yn | egrep -io '^n'`" ]; then
        break
    fi
    setup_mongodb "" "" "27017"
done

# Once config file is all set. We make a final substitution to remove place holders
sed -i "s/  - ANOTHER-ADMIN-SERVER//g" $CONFIG_FILE
sed -i "s/  - ANOTHER-DB-SERVER//g" $CONFIG_FILE
sed -i "s/    - ANOTHER-DB//g" $CONFIG_FILE

chown -R $COPPEREGG_USER:$COPPEREGG_GROUP /usr/local/copperegg/ucm-metrics/*mongo*

echo
echo
echo "------------------------------------------------------------------"
echo
echo "Done creating config file $CONFIG_FILE"
echo

# Method to create init file, based on machine's Init system
create_init_file
