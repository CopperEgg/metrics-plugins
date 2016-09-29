#!/bin/bash

setup_base_group()
{
    TYPE_LOWER="$1"
    TYPE_UPPER="$2"

    echo
    echo "Configuring $TYPE_UPPER"

    echo -n "group_name: [$TYPE_LOWER] "
    read GROUP_NAME
    if [ -z "$GROUP_NAME" ]; then
        GROUP_NAME="$TYPE_LOWER"
    fi

    echo -n "group_label: [$TYPE_UPPER Metrics] "
    read GROUP_LABEL
    if [ -z "$GROUP_LABEL" ]; then
        GROUP_LABEL="$TYPE_UPPER Metrics"
    fi

    echo -n "dashboard: [$TYPE_UPPER] "
    read DASHBOARD
    if [ -z "$DASHBOARD" ]; then
        DASHBOARD="$TYPE_UPPER"
    fi

    echo "$TYPE_LOWER:" >> $CONFIG_FILE
    echo "  group_name: \"$GROUP_NAME\"" >> $CONFIG_FILE
    echo "  group_label: \"$GROUP_LABEL\"" >> $CONFIG_FILE
    echo "  dashboard: \"$DASHBOARD\"" >> $CONFIG_FILE
    echo "  servers:" >> $CONFIG_FILE
}

setup_mysql_server()
{

    DEFAULT_LABEL="$1"
    DEFAULT_HOSTNAME="$2"
    DEFAULT_USERNAME="$3"
    DEFAULT_PASSWORD="$4"
    DEFAULT_DATABASE="$5"

    echo -n "unique_id: [$DEFAULT_LABEL] "
    read LABEL
    if [ -z "$LABEL" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "unique_id cannot be blank"
            return 1
        fi
        LABEL="$DEFAULT_LABEL"
    fi

    echo -n "hostname: [$DEFAULT_HOSTNAME] "
    read HOST_NAME
    if [ -z "$HOST_NAME" ]; then
        if [ -z "$DEFAULT_HOSTNAME" ]; then
            echo "hostname cannot be blank"
            return 1
        fi
        HOST_NAME="$DEFAULT_HOSTNAME"
    fi

    echo -n "username: [$DEFAULT_USERNAME] "
    read USER_NAME
    if [ -z "$USER_NAME" ]; then
        if [ -z "$DEFAULT_USERNAME" ]; then
            echo "username cannot be blank"
            return 1
        fi
        USER_NAME="$DEFAULT_USERNAME"
    fi

    echo -n "password: [$DEFAULT_PASSWORD] "
    read PASSWORD
    if [ -z "$PASSWORD" ]; then
        # password is allowed to be blank
        PASSWORD="$DEFAULT_PASSWORD"
    fi

    echo -n "database: [$DEFAULT_DATABASE] "
    read DATABASE
    if [ -z "$DATABASE" ]; then
        if [ -z "$DEFAULT_DATABASE" ]; then
            echo "database cannot be blank"
            return 1
        fi
        DATABASE="$DEFAULT_DATABASE"
    fi

    P_FLAG=""
    if [ -n "$PASSWORD" ]; then
        P_FLAG="-p"
    fi

    echo
    echo "Testing with command: echo 'show global status;' | mysql -h $HOST_NAME -u $USER_NAME $P_FLAG $DATABASE > /tmp/mysql_global_status.txt"
    echo 'show global status;' | mysql -h $HOST_NAME -u $USER_NAME $P_FLAG $DATABASE > /tmp/mysql_global_status.txt
    if [ $? -ne 0 -o -z "`cat /tmp/mysql_global_status.txt | grep Uptime`" ]; then
        echo
        echo "WARNING: Could not connect to mysql host $HOST_NAME with"
        echo "  username $USER_NAME database $DATABASE to get status."
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
    echo "    name: \"$LABEL\"" >> $CONFIG_FILE
    echo "    hostname: \"$HOST_NAME\"" >> $CONFIG_FILE
    echo "    username: \"$USER_NAME\"" >> $CONFIG_FILE
    echo "    password: \"$PASSWORD\"" >> $CONFIG_FILE
    echo "    database: \"$DATABASE\"" >> $CONFIG_FILE

}

setup_redis_server()
{

    DEFAULT_LABEL="$1"
    DEFAULT_HOSTNAME="$2"
    DEFAULT_PORT="$3"

    echo -n "unique_id: [$DEFAULT_LABEL] "
    read LABEL
    if [ -z "$LABEL" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "unique_id cannot be blank"
            return 1
        fi
        LABEL="$DEFAULT_LABEL"
    fi

    echo -n "hostname: [$DEFAULT_HOSTNAME] "
    read HOST_NAME
    if [ -z "$HOST_NAME" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "hostname cannot be blank"
            return 1
        fi
        HOST_NAME="$DEFAULT_HOSTNAME"
    fi

    echo -n "port: [$DEFAULT_PORT] "
    read PORT
    if [ -z "$PORT" ]; then
        if [ -z "$DEFAULT_PORT" ]; then
            echo "port cannot be blank"
            return 1
        fi
        PORT="$DEFAULT_PORT"
    fi

    echo
    echo "Testing with command: redis-cli -h $HOST_NAME -p $PORT info > /tmp/redis_info.txt"
    redis-cli -h $HOST_NAME -p $PORT info > /tmp/redis_info.txt
    if [ $? -ne 0 ]; then
        echo
        echo "WARNING: Could not connect to host $HOST_NAME to get status."
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
    echo "    name: \"$LABEL\"" >> $CONFIG_FILE
    echo "    hostname: \"$HOST_NAME\"" >> $CONFIG_FILE
    echo "    port: $PORT" >> $CONFIG_FILE

}


setup_apache_server()
{

    DEFAULT_LABEL="$1"
    DEFAULT_URL="$2"

    echo -n "unique_id: [$DEFAULT_LABEL] "
    read LABEL
    if [ -z "$LABEL" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "unique_id cannot be blank"
            return 1
        fi
        LABEL="$DEFAULT_LABEL"
    fi

    echo -n "url: [$DEFAULT_URL] "
    read URL
    if [ -z "$URL" ]; then
        if [ -z "$DEFAULT_URL" ]; then
            echo "url cannot be blank"
            return 1
        fi
        URL="$DEFAULT_URL"
    fi

    echo
    echo "Testing with command: curl -s $URL/server-status?auto > /tmp/apache_status.txt"
    curl -s $URL/server-status?auto > /tmp/apache_status.txt
    if [ $? -ne 0 ]; then
        echo
        echo "WARNING: Could not connect to $URL/server-status?auto to get status."
        echo "  Be sure to enable apache mod_status per instructions here:"
        echo "  http://httpd.apache.org/docs/2.2/mod/mod_status.html"
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
    echo "    name: \"$LABEL\"" >> $CONFIG_FILE
    echo "    url: \"$URL\"" >> $CONFIG_FILE


}

setup_nginx_server()
{
    DEFAULT_LABEL="$1"
    DEFAULT_URL="$2"

    echo -n "unique_id: [$DEFAULT_LABEL] "
    read LABEL
    if [ -z "$LABEL" ]; then
        if [ -z "$DEFAULT_LABEL" ]; then
            echo "unique_id cannot be blank"
            return 1
        fi
        LABEL="$DEFAULT_LABEL"
    fi

    echo -n "url: [$DEFAULT_URL] "
    read URL
    if [ -z "$URL" ]; then
        if [ -z "$DEFAULT_URL" ]; then
            echo "url cannot be blank"
            return 1
        fi
        URL="$DEFAULT_URL"
    fi

    echo
    echo "Testing with command: curl -s $URL/nginx_status?auto > /tmp/nginx_status.txt"
    curl -s $URL/nginx_status?auto > /tmp/nginx_status.txt
    if [ $? -ne 0 ]; then
        echo
        echo "WARNING: Could not connect to $URL/nginx_status?auto to get status."
        echo "  Be sure to enable nginx HttpStubStatusModule per instructions here:"
        echo "  http://wiki.nginx.org/HttpStubStatusModule"
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
    echo "    name: \"$LABEL\"" >> $CONFIG_FILE
    echo "    url: \"$URL\"" >> $CONFIG_FILE

}


#
# Functions for init scripts
#

create_exe_file()
{
    LAUNCHER_FILE="/usr/local/copperegg/ucm-metrics/revealmetrics_common_metrics_launcher.sh"
    if [ -n "$RVM_SCRIPT" ]; then
        cat <<ENDINIT > $LAUNCHER_FILE
#!/bin/bash
DIRNAME="/usr/local/copperegg/ucm-metrics/common_metrics"
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

setup_upstart_init()
{
    stop revealmetrics-agent >/dev/null 2>&1 # old-named init file.
    rm -f /etc/init/revealmetrics-agent.conf # just blast it away.

    INIT_FILE="/etc/init/revealmetrics_common_metrics.conf"
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
            echo -n "log file: [/usr/local/copperegg/log/ucm_common_metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/copperegg/log/ucm_common_metrics.log"
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
        echo "Thank you for setting up the CopperEgg Metrics Agent."
        echo "You may use 'sudo [start|stop] `basename $INIT_FILE .conf` to start/stop the agent"
        echo
        start `basename $INIT_FILE .conf`
        echo
    fi
}

setup_standard_init()
{
    /etc/init.d/revealmetrics_common_metrics stop >/dev/null 2>&1 # old-named init file.
    rm -f /etc/init.d/revealmetrics_common_metrics                # just blast it away.

    INIT_FILE="/etc/init.d/revealmetrics_common_metrics"
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
            echo -n "log file: [/usr/local/copperegg/log/ucm_common_metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/copperegg/log/ucm_common_metrics.log"
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
# Provides:           copperegg-metrics
# Required-Start:     \$syslog
# Required-Stop:      \$syslog
# Default-Start:      2 3 4 5
# Default-Stop:       0 1 6
# Short-Description:  analytics collection for CopperEgg Custom Metrics
# Description:        <support-uptimecm@idera.com>
#
### END INIT INFO

# Author: CopperEgg <support-uptimecm@idera.com>
#

PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
RUBY_DAEMON=$AGENT_FILE
DAEMON=$EXE_FILE
CONFIGFILE=$CONFIG_FILE
LOGFILE=$LOGFILE
COPPEREGG_USER=$COPPEREGG_USER
DESC="custom analytics collection for Uptime Cloud Monitor"
NAME=copperegg-metrics

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
            rm -f /etc/rc*.d/*revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc0.d/K99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc1.d/K99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc2.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc3.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc4.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc5.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/rc6.d/K99revealmetrics_common_metrics
        elif [ -d "/etc/init.d/rc1.d" ]; then
            rm -f /etc/init.d/rc*.d/*revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc1.d/K99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc2.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc3.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc4.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc5.d/S99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rc6.d/K99revealmetrics_common_metrics
            ln -s $INIT_FILE /etc/init.d/rcS.d/S99revealmetrics_common_metrics
        fi

        echo
        echo "Thank you for setting up the Uptime Cloud Monitor Metrics Agent."
        echo "You may use 'sudo $INIT_FILE [start|stop]' to start/stop the agent"
        echo
        $INIT_FILE start
        echo
    fi
}


#
# Other function
#

print_notes()
{
    TYPE=$1
    case "$TYPE" in
    "apache")
        echo
        echo "Apache notes:"
        echo "Please ensure that mod_status is enabled on the server(s):"
        echo "  http://httpd.apache.org/docs/2.2/mod/mod_status.html"
        echo "And that this host can access the status page:"
        echo "  curl -s http://your-server:80/server-status?auto"
        echo
        ;;
    "nginx")
        echo
        echo "Nginx notes:"
        echo "Please ensure that stub_status is enabled on the server(s):"
        echo "  http://wiki.nginx.org/HttpStubStatusModule"
        echo "And that this host can access the status page:"
        echo "  curl -s http://your-server:80/nginx_status"
        echo
        ;;
    *)
        echo
        echo "$TYPE notes:"
        echo "Please ensure that this host has access to each $TYPE server"
        echo "that you specify in the config section"
        echo
        ;;
    esac

}


###############################################################
###############################################################
##   End Functions, start main code
###############################################################
###############################################################

echo
SUPPORTED_TYPES="mysql redis apache nginx"
MON_LIST=""
if [ -z "$MON_LIST" ]; then
    # if user didn't set the env var, ask them
    MON_LIST=""
    for CONFIG_TYPE in $SUPPORTED_TYPES; do
        echo -n "Configure $CONFIG_TYPE monitoring? [yN] "
        read yn
        if [ -n "`echo $yn | egrep -io '^y'`" ]; then
            MON_LIST="$CONFIG_TYPE $MON_LIST"
            print_notes $CONFIG_TYPE
        fi
    done
fi

if [ -z "$MON_LIST" ]; then
    echo
    echo "No monitoring selected.  Please re-run and select (type 'yes' for) at least one thing to monitor."
    echo "Exiting."
    echo
    exit 1
fi

MONITOR_MYSQL="`echo $MON_LIST | egrep -o 'mysql'`"
MONITOR_REDIS="`echo $MON_LIST | egrep -o 'redis'`"
MONITOR_APACHE="`echo $MON_LIST | egrep -o 'apache'`"
MONITOR_NGINX="`echo $MON_LIST | egrep -o 'nginx'`"


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
echo "Installing gems..."

#if [ -n "$BUNDLE" ]; then
# Don't install using bundler.  It's annoying and doesn't work half the time.
if false; then
    # Don't set BUNDLE_PARAMS to "", just in case we want to export it in
    if [ -z "$MONITOR_MYSQL" ]; then
        BUNDLE_PARAMS="$BUNDLE_PARAMS --without=mysql"
    fi
    if [ -z "$MONITOR_REDIS" ]; then
        BUNDLE_PARAMS="$BUNDLE_PARAMS --without=redis"
    fi
    bundle install $BUNDLE_PARAMS
else
    gem install --no-ri --no-rdoc json_pure --source 'http://rubygems.org' >> $PKG_INST_OUT 2>&1
    if [ $? -ne 0 ]; then
        echo
        echo -n "You have an old version of rubygems.  May I upgrade it for you? [Yn] "
        read yn
        if [ -z "`echo $yn | egrep -io '^n'`" ]; then
            echo "Updating rubygems..."
            gem install --no-ri --no-rdoc rubygems-update >> $PKG_INST_OUT 2>&1
            EXE_DIR="`gem environment | grep 'EXECUTABLE DIRECTORY' |cut -d ':' -f 2 | sed -e 's/^ //'`"
            PATH=$PATH:$EXE_DIR
            update_rubygems >> $PKG_INST_OUT 2>&1
            if [ $? -ne 0 ]; then
                echo
                echo "ERROR: Could not update rubygems.  Please report this to support-uptimecm@idera.com"
                echo "  and include all this output, plus the file: $PKG_INST_OUT"
                echo
                exit 1
            fi
        else
            echo "Please update rubygems manually and re-run this command."
            exit 1
        fi
    fi

    if [ -n "$MONITOR_MYSQL" ]; then
        gem install --no-ri --no-rdoc mysql2 --source 'http://rubygems.org' >> $PKG_INST_OUT 2>&1
        if [ $? -ne 0 ]; then
            echo
            echo "Mysql dev package is required to monitor mysql."
            echo -n "May I install it for you? [Yn] "
            read yn
            if [ -z "`echo $yn | egrep -io '^n'`" ]; then
                install_rc=1
                if [ -n "`which apt-get 2>/dev/null`" ]; then
                    echo "Installing libmysqld-dev with apt-get.  This may take a few minutes..."
                    apt-get update >> $PKG_INST_OUT 2>&1
                    if [ -z "$RVM_SCRIPT" ]; then
                        apt-get -y install ruby-dev >> $PKG_INST_OUT 2>&1
                    fi
                    apt-get -y install libmysqld-dev build-essential >> $PKG_INST_OUT 2>&1
                    install_rc=$?
                elif [ -n "`which yum 2>/dev/null`" ]; then
                    echo "Installing mysql dev package with yum.  This may take a few minutes..."
                    yum list installed > /tmp/yum-list-installed.txt 2>&1
                    PACKAGES="gcc make ruby-devel rubygems"
                    if [ -z "$RVM_SCRIPT" ]; then
                        PACKAGES="gcc make"
                    fi
                    for THIS_PKG in $PACKAGES; do
                        echo "Installing $THIS_PKG..." >> $PKG_INST_OUT 2>&1
                        yum -y install $THIS_PKG >> $PKG_INST_OUT 2>&1
                    done

                    yum list installed > /tmp/yum-list-installed.txt 2>&1
                    REPO_ARG=""
                    if [ -n "`cat /tmp/yum-list-installed.txt | egrep '^mysql5[0-9]\.'`" ]; then
                        PKG_TO_INST="`cat /tmp/yum-list-installed.txt | egrep '^mysql5[0-9]\.' | head -1 | awk '{print $1}' | sed 's/\./-devel./'`"
                        if [ -n "`yum list 2>/dev/null | grep webtatic`" ]; then
                            REPO_ARG="--enablerepo=webtatic"
                        fi
                    elif [ -n "`cat /tmp/yum-list-installed.txt | egrep -i '^Percona-Server'`" ]; then
                        PKG_TO_INST="`cat /tmp/yum-list-installed.txt | egrep -i '^Percona-Server-client' | head -1 | awk '{print $1}' | sed 's/client/devel/'`"
                        if [ -z "$PKG_TO_INST" ]; then
                            PKG_TO_INST="`cat /tmp/yum-list-installed.txt | egrep -i Percona-Server-server | head -1 | awk '{print $1}' | sed 's/server/devel/'`"
                        fi
                    else
                        PKG_TO_INST="mysql-devel"
                    fi
                    if [ -n "$PKG_TO_INST" ]; then
                        echo -n "  Installing $PKG_TO_INST"
                        if [ -n "$REPO_ARG" ]; then
                            echo " with repo $REPO_ARG"
                        else
                            echo
                        fi
                        yum -y install $PKG_TO_INST $REPO_ARG >> $PKG_INST_OUT 2>&1
                    else
                        echo
                        echo "  ERROR: couldn't properly detect what mysql dev package to use!"
                        echo "  You may have to install one manually and rerun this installer."
                        echo "  Contact support-uptimecm@idera.com for further assistance"
                        echo -n "  Press enter to continue, or ctrl-c to quit.  []"
                        read yn
                        echo
                    fi

                    install_rc=$?
                else
                    echo
                    echo "ERROR: could not find 'yum' or 'apt-get'.  Please install the mysql dev package for your distro."
                    exit 1
                fi
                if [ $install_rc -ne 0 ]; then
                    echo
                    echo "ERROR: Could not install mysql dev package.  Please report this to support-uptimecm@idera.com"
                    echo "  and include all this output, plus the file: $PKG_INST_OUT"
                    echo
                    exit 1
                fi
            else
                echo
                echo "Please install the mysql dev package, or rerun this script without"
                echo "enabling mysql monitoring.  Email support-uptimecm@idera.com for assistance."
                echo
                exit 1
            fi
        fi
    fi

    echo

    echo "Installing gem bundler [Using gem install bundler -v \"1.12.5\"]"

        gem install bundler -v "1.12.5" >> $PKG_INST_OUT

    IFS=$'\n'
    gems=`grep -w gem common_metrics/Gemfile | awk '{$1="" ; print $0}'`

    for gem in $gems; do
        gem_name=`echo $gem | awk -F "," '{print $1}' | tr -d \' | tr -d \" | tr -d [:blank:]`
        gem_version=`echo $gem | awk -F "," '{print $2}' | tr -d \' | tr -d \" | tr -d [:blank:]`

        if [ -n "`echo $gem_name | egrep mysql`" -a -z "$MONITOR_MYSQL" ]; then
            # skip installing mysql gem if user doesn't need it
            continue
        fi
        if [ -n "`echo $gem_name | egrep redis`" -a -z "$MONITOR_REDIS" ]; then
            # skip installing redis gem if user doesn't need it
            continue
        fi

        echo "Installing gem $gem_name [Using gem install $gem_name -v \"$gem_version\"]"

        gem install $gem_name -v "$gem_version" >> $PKG_INST_OUT
        install_rc=$?
        if [ $install_rc -ne 0 ]; then
            echo
            echo "********************************************************"
            echo "*** "
            echo "*** WARNING: gem $gem did not install properly!"
            echo "*** Please contact support-uptimecm@idera.com if you are"
            echo "*** unable to run 'gem install $gem_name -v \"$gem_version\"' manually."
            echo "*** "
            echo "********************************************************"
            echo
        fi
    done
    IFS=$' '
fi


#
# create config.yml
#
echo
echo
echo "------------------------------------------------------------------"
echo
CONFIG_FILE="/usr/local/copperegg/ucm-metrics/common_metrics/config.yml"
AGENT_FILE="/usr/local/copperegg/ucm-metrics/common_metrics/common_metrics.rb"
CREATE_CONFIG="yes"

if [ -n "`echo $CREATE_CONFIG | egrep -io '^y'`" ]; then
    echo
    echo "NOTE: For ease of setup and administration, it is recommended that you set up"
    echo "  all of your servers to be monitored from one place.  When specifying servers"
    echo "  below, please enter all servers that you wish to monitor for each type."
    echo "  If you want to start with one, you can easily edit the config file later,"
    echo "  and add them if you wish.  You will need to restart the agent for the"
    echo "  changes to take effect."
    echo
    echo "Creating config.yml.  Press enter to use the default [in brackets]"
    echo

    echo "copperegg:" > $CONFIG_FILE
    echo "  apikey: \"$API_KEY\"" >> $CONFIG_FILE
    echo "  frequency: $FREQ" >> $CONFIG_FILE
    echo "  services:" >> $CONFIG_FILE
    for SERVICE in $MON_LIST; do
        echo "  - $SERVICE" >> $CONFIG_FILE
    done

    # redis
    if [ -n "$MONITOR_REDIS" ]; then
        setup_base_group "redis" "Redis"

        rc=1
        while [ $rc -ne 0 ]; do
            # loop with defaults until they get it right
            echo "Configuring first redis server (required)"
            setup_redis_server "`hostname | sed 's/ /_/g'`-redis" "localhost" "6379"
            rc=$?
        done

        while true; do
            echo -n "Add another redis server? [Yn] "
            read yn
            if [ -n "`echo $yn | egrep -io '^n'`" ]; then
                break
            fi
            setup_redis_server "" "" "6379"
        done
    fi

    # mysql
    if [ -n "$MONITOR_MYSQL" ]; then
        setup_base_group "mysql" "MySQL"

        rc=1
        while [ $rc -ne 0 ]; do
            # loop with defaults until they get it right
            echo "Configuring first mysql server (required)"
            setup_mysql_server "`hostname | sed 's/ /_/g'`-mysql" "localhost" "root" "" "mysql"
            rc=$?
        done

        while true; do
            echo -n "Add another mysql server? [Yn] "
            read yn
            if [ -n "`echo $yn | egrep -io '^n'`" ]; then
                break
            fi
            setup_mysql_server "" "" "" "" ""
        done

    fi

    # apache
    if [ -n "$MONITOR_APACHE" ]; then
        setup_base_group "apache" "Apache"

        rc=1
        while [ $rc -ne 0 ]; do
            # loop with defaults until they get it right
            echo "Configuring first apache server (required)"
            setup_apache_server "`hostname | sed 's/ /_/g'`-apache" "http://localhost"
            rc=$?
        done


        while true; do
            echo -n "Add another apache server? [Yn] "
            read yn
            if [ -n "`echo $yn | egrep -io '^n'`" ]; then
                break
            fi
            setup_apache_server "" ""
        done
    fi


    # nginx
    if [ -n "$MONITOR_NGINX" ]; then
        setup_base_group "nginx" "Nginx"

        rc=1
        while [ $rc -ne 0 ]; do
            # loop with defaults until they get it right
            echo "Configuring first nginx server (required)"
            setup_nginx_server "`hostname | sed 's/ /_/g'`-nginx" "http://localhost"
            rc=$?
        done


        while true; do
            echo -n "Add another nginx server? [Yn] "
            read yn
            if [ -n "`echo $yn | egrep -io '^n'`" ]; then
                break
            fi
            setup_nginx_server "" ""
        done
    fi

fi


chown -R $COPPEREGG_USER:$COPPEREGG_GROUP /usr/local/copperegg/ucm-metrics*

echo
echo
echo "------------------------------------------------------------------"
echo
echo "Done creating config file $CONFIG_FILE"
echo

CREATED_INIT=""
if [ -d "/etc/init" -a -n "`which start 2>/dev/null`" ]; then
    # uncomment to test the init.d method on an ubuntu system:
    #echo "upstart exists but installing standard anyway"
    #setup_standard_init

    setup_upstart_init

elif [ -d "/etc/init.d" ]; then
    setup_standard_init

fi

if [ -z "$CREATED_INIT" ]; then
    echo
    echo "Thank you for setting up the Uptime Cloud Monitor Metrics Agent."
    echo "You may run it using the following command:"
    echo "  nohup ruby $AGENT_FILE --config $CONFIG_FILE >/tmp/copperegg-metrics.log 2>&1 &"
    echo
fi

echo
echo "Install complete!"
echo "If you have any questions, please contact support-uptimecm@idera.com"
