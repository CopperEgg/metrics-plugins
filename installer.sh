#!/bin/bash

###############################################################
###############################################################
##   Functions
###############################################################
###############################################################

#
# functions for config.yml
#

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

setup_couchdb()
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
    echo -n "Hint : Include http:// or https:// in the beginning [Eg http://your_server_name.com]"
    read URL
    if [ -z "$URL" ]; then
        if [ -z "$DEFAULT_URL" ]; then
            echo "Hostname cannot be blank"
            return 1
        fi
        URL="$DEFAULT_URL"
    fi

    echo -n "Username: "
    read USER_NAME

    echo -n "Password: "
    read PASSWORD

    echo -n "Port: [5984]"
    read PORT
    if [ -z "$PORT" ]; then
        PORT="$DEFAULT_PORT"
    fi

    echo
    if [ -z $USER_NAME ]; then
        echo "Testing with command: curl $URL:$PORT/_stats"
        curl "$URL:$PORT/_stats" > /tmp/couchdb_stats.txt
    else
        echo "Testing with command: curl -u $USER_NAME:$PASSWORD $URL:$PORT/_stats"
        curl -u $USER_NAME:$PASSWORD "$URL:$PORT/_stats" > /tmp/couchdb_stats.txt
    fi

    # grep any one metric from the output file
    if [ -z "`grep 'auth_cache_misses' /tmp/couchdb_stats.txt`" ]; then
        echo
        echo "WARNING: Could not connect to CouchDB Server with $URL, "
        echo "  username $USER_NAME, password $PASSWORD and port $PORT to get status."
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
    echo "    name: \"$LABEL\""               >> $CONFIG_FILE
    echo "    url: \"$URL:$PORT\"" >> $CONFIG_FILE
    echo "    user: \"$USER_NAME\""       >> $CONFIG_FILE
    echo "    password: \"$PASSWORD\""        >> $CONFIG_FILE
}

create_exe_file()
{
    LAUNCHER_FILE="/usr/local/ucm/ucm-agent-launcher.sh"
    if [ -n "$RVM_SCRIPT" ]; then
        cat <<ENDINIT > $LAUNCHER_FILE
#!/bin/bash
DIRNAME="`dirname \$0`"
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
    INIT_FILE="/etc/init/ucm-metrics.conf"
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
            echo -n "log file: [/usr/local/ucm/log/ucm-metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/ucm/log/ucm-metrics.log"
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
    /etc/init.d/copperegg-agent stop >/dev/null 2>&1 # old-named init file.
    rm -f /etc/init.d/copperegg-agent                # just blast it away.

    INIT_FILE="/etc/init.d/copperegg-metrics"
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
            echo -n "log file: [/usr/local/ucm/log/ucm-metrics.log] "
            read LOGFILE
            if [ -z "$LOGFILE" ]; then
                LOGFILE="/usr/local/ucm/log/ucm-metrics.log"
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
            rm -f /etc/rc*.d/*copperegg-metrics
            ln -s $INIT_FILE /etc/rc0.d/K99copperegg-metrics
            ln -s $INIT_FILE /etc/rc1.d/K99copperegg-metrics
            ln -s $INIT_FILE /etc/rc2.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/rc3.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/rc4.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/rc5.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/rc6.d/K99copperegg-metrics
        elif [ -d "/etc/init.d/rc1.d" ]; then
            rm -f /etc/init.d/rc*.d/*copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc1.d/K99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc2.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc3.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc4.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc5.d/S99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rc6.d/K99copperegg-metrics
            ln -s $INIT_FILE /etc/init.d/rcS.d/S99copperegg-metrics
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
    "couchdb")
        echo
        echo "CouchDB notes:"
        echo "Please ensure that this sytem is able to access the couchdb databases"
    esac
}


###############################################################
###############################################################
##   End Functions, start main code
###############################################################
###############################################################



echo
echo "For yes/no questions, type 'y' for yes, 'n' for no."
echo "Or press Enter to use the default answer."

echo
SUPPORTED_TYPES="couchdb"

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

MONITOR_COUCHDB="`echo $MON_LIST | egrep -o 'couchdb'`"

if [ -n "`which useradd 2>/dev/null`" ]; then
    COPPEREGG_USER="copperegg"
    COPPEREGG_GROUP="copperegg"
else
    COPPEREGG_USER="root"
    COPPEREGG_GROUP="root"
fi

echo > $PKG_INST_OUT

sleep 1
echo
echo
echo "Checking Dependencies..."

HAS_RUBYSSL=""
INSTALL_RVM=""
RVM_SCRIPT=""
if [ -f "/usr/local/rvm/scripts/rvm" ]; then
    RVM_SCRIPT="/usr/local/rvm/scripts/rvm"
    export RVM_SCRIPT
    . $RVM_SCRIPT
    echo "Detected system-level rvm install."
    echo "Ruby path = `which ruby 2>/dev/null`"
    echo "Ruby version = `ruby --version`"
    echo -n "Is this correct? 'Yes' if unsure. [Yn] "
    read yn
    if [ -z "`echo $yn | egrep -io '^n'`" ]; then
        INSTALL_RVM=""
        RVM_TYPE="system"
        echo "Ok, using existing rvm"
    else
        USE_RUBY="`rvm list default string`"
        echo "Detected rvm rubies: `rvm list string`"
        echo -n "Which ruby version should I use? [$USE_RUBY]"
        read RUBY_TMP
        if [ -z "$RUBY_TMP" ]; then
            # do nothing, just keep USE_RUBY as is
            echo
        elif [ -z "`rvm list string | egrep $RUBY_TMP`" ]; then
            echo "Invalid ruby $RUBY_TMP."
        elif [ -n "$RUBY_TMP" ]; then
            USE_RUBY=$RUBY_TMP
        fi
        echo "Using $USE_RUBY"
    fi
elif [ -f "$HOME/.rvm/scripts/rvm" ]; then
    # skip for now
    break #FIXME: we should be able to use a user-land rvm install

    RVM_SCRIPT="$HOME/.rvm/scripts/rvm"
    export RVM_SCRIPT
    echo "Detected user-level rvm install."
    echo "Ruby path = `which ruby`"
    echo "Ruby version = `ruby --version`"
    echo -n "Is this correct? 'Yes' if unsure. [Yn] "
    read yn
    if [ -z "`echo $yn | egrep -io '^n'`" ]; then
        INSTALL_RVM=""
        RVM_TYPE="user"
        COPPEREGG_USER="`whoami`"
        COPPEREGG_GROUP="`groups|awk '{print $1}'`"

    else
        echo "Ok, skipping rvm"
        #echo "which rvm ruby should I use? [`rvm list default string`] "
    fi
fi
echo

if [ -n "$SUGGEST_RVM" -a -z "$RVM_TYPE" ]; then
    # install system-level rvm
    echo "It is highly recommended to install and use rvm on this system."
    echo "Doing so will avoid pain points known to exist with the system ruby."
    echo -n "May I install it for you? 'Yes' if unsure. [Yn] "
    read yn
    if [ -z "`echo $yn | egrep -io '^n'`" ]; then
        echo "Installing RVM.  This may take a few minutes."
        echo
        if [ -n "`which yum 2>/dev/null`" ]; then
            yum -y install openssl openssl-devel >> $PKG_INST_OUT 2>&1
            if [ "$OS" == "centos5" ]; then
                yum install -y gcc-c++ patch readline readline-devel zlib zlib-devel libyaml-devel libffi-devel openssl-devel make bzip2 autoconf automake libtool bison patch git >> $PKG_INST_OUT 2>&1
            fi
        fi
        \curl -s -L https://get.rvm.io | bash -s stable --ruby >> $PKG_INST_OUT 2>&1
        RVM_SCRIPT="/usr/local/rvm/scripts/rvm"
        export RVM_SCRIPT
        . $RVM_SCRIPT
        RVM_TYPE="system"
        HAS_RUBYSSL="skip"
    fi
fi

if [ -z "$RVM_TYPE" ]; then
    echo -n "Do you have a custom ruby install (eg ree/rvm)? 'No' if unsure. [yN] "
    read yn
    if [ -n "`echo $yn | egrep -io '^y'`" ]; then
        echo -n "What is the path to your ruby? [`which ruby 2>/dev/null`] "
        read RUBY_PATH
        if [ -z "$RUBY_PATH" ]; then
            RUBY_PATH="`which ruby 2>/dev/null`"
            if [ -z "$RUBY_PATH" ]; then
                echo "ERROR: Path to ruby executable cannot be blank!"
                exit 1
            fi
            if [ -f "$RUBY_PATH" ]; then
                RUBY_PATH="`dirname $RUBY_PATH`"
            fi
            if [ ! -d "$RUBY_PATH" ]; then
                echo "ERROR: $RUBY_PATH is not a directory!"
                exit 1
            fi
            PATH="$RUBY_PATH:$PATH"
            export PATH
        fi
        HAS_RUBYSSL="skip"
    fi
fi


if [ -n "$HAS_RUBYSSL" ]; then
    # just skip if its non-null
    HAS_RUBYSSL="skip"
elif [ -n "`which dpkg 2>/dev/null`" ]; then
    HAS_RUBYSSL="`dpkg --list | egrep 'libopenssl-ruby|libruby'`"
elif [ -n "`which yum 2>/dev/null`" ]; then
    HAS_RUBYSSL="`yum list installed | egrep ruby-libs`"
    if [ -n "$HAS_RUBYSSL" ]; then
        # be sure it has both ruby-libs and ruby-devel
        HAS_RUBYSSL="`yum list installed | egrep ruby-devel`"
    fi
else
    HAS_RUBYSSL="skip"
fi

if [ -z "$HAS_RUBYSSL" ]; then
    echo
    echo -n "Ruby SSL support is not installed.  May I install it for you? [Yn] "
    read yn
    if [ -z "`echo $yn | egrep -io '^n'`" ]; then
        install_rc=0
        if [ -n "`which apt-get 2>/dev/null`" ]; then
            echo "Installing Ruby+SSL with apt-get.  This may take a few minutes..."
            apt-get update >> $PKG_INST_OUT 2>&1
            apt-get -y install ruby libopenssl-ruby ruby-dev >> $PKG_INST_OUT 2>&1
            install_rc=$?
        elif [ -n "`which yum 2>/dev/null`" ]; then
            echo "Installing Ruby+SSL with yum.  This may take a few minutes..."
            yum -y install ruby ruby-devel ruby-libs >> $PKG_INST_OUT 2>&1
            install_rc=$?
        else
            # This should not happen, but if it does just warn
            echo "Warn: could not install Ruby+SSL"
        fi
        if [ $install_rc -ne 0 ]; then
            echo
            echo "ERROR: Could not install ruby.  Please report this to support-uptimecm@idera.com"
            echo "  and include all this output, plus the file: $PKG_INST_OUT"
            echo
            exit 1
        fi
    else
        echo "Ruby SSL support is required.  Please install it manually or allow this script to."
        exit 1
    fi
fi

if [ -z "$GEM" ]; then
    GEM="`which gem 2>/dev/null`"
    if [ $? -ne 0 -o -z "$GEM" ]; then
        echo
        echo -n "rubygems is required but not installed.  May I install it for you? [Yn] "
        read yn
        if [ -z "`echo $yn | egrep -io '^n'`" ]; then
            install_rc=1
            if [ -n "`which apt-get 2>/dev/null`" ]; then
                echo "Installing rubygems with apt-get.  This may take a few minutes..."
                apt-get update >> $PKG_INST_OUT 2>&1
                apt-get -y install rubygems >> $PKG_INST_OUT 2>&1
                gem install --no-ri --no-rdoc rubygems-update >> $PKG_INST_OUT 2>&1
                EXE_DIR="`gem environment | grep 'EXECUTABLE DIRECTORY' |cut -d ':' -f 2 | sed -e 's/^ //'`"
                PATH=$PATH:$EXE_DIR
                update_rubygems >> $PKG_INST_OUT 2>&1
                install_rc=$?
            elif [ -n "`which yum 2>/dev/null`" ]; then
                echo "Installing rubygems with yum.  This may take a few minutes..."
                yum -y install rubygems >> $PKG_INST_OUT 2>&1
                gem install --no-ri --no-rdoc rubygems-update >> $PKG_INST_OUT 2>&1
                EXE_DIR="`gem environment | grep 'EXECUTABLE DIRECTORY' |cut -d ':' -f 2 | sed -e 's/^ //'`"
                PATH=$PATH:$EXE_DIR
                update_rubygems >> $PKG_INST_OUT 2>&1
                install_rc=$?
            else
                echo
                echo "ERROR: could not find 'yum' or 'apt-get'.  Please install the rubygems package for your distro."
                exit 1
            fi
            if [ $install_rc -ne 0 ]; then
                echo
                echo "ERROR: Could not install rubygems package.  Please report this to support-uptimecm@idera.com"
                echo "  and include all this output, plus the file: $PKG_INST_OUT"
                echo
                exit 1
            fi
        else
            echo "Please install rubygems and rerun this command"
            exit 1
        fi
    fi
fi

if [ -z "$BUNDLE" ]; then
    # use if there, but no whine if not
    BUNDLE="`which bundle 2>/dev/null`"
fi

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
echo -n "User to run agent as: [copperegg] "
read C_USER
if [ -n "$C_USER" ]; then
    COPPEREGG_USER="$C_USER"
fi

echo -n "Group to run agent as: [copperegg] "
read C_GROUP
if [ -n "$C_GROUP" ]; then
    COPPEREGG_GROUP="$C_GROUP"
fi

if [ -n "`which useradd 2>/dev/null`" ]; then
    groupadd $COPPEREGG_GROUP 2>/dev/null
    useradd -mr -g $COPPEREGG_GROUP $COPPEREGG_USER 2>/dev/null
    if [ -n "`cat /etc/group | egrep '^rvm:'`" ]; then
        usermod -a -G rvm $COPPEREGG_USER
    fi
fi

if [ -z "`awk -F':' '{ print $1 }' /etc/passwd | egrep \"^$COPPEREGG_USER$\"`" ]; then
    echo "WARNING: user '$COPPEREGG_USER' does not exist and could not be created.  Using 'root' instead."
    COPPEREGG_USER="root"
    COPPEREGG_GROUP="root"
fi

echo
echo "Installing gems..."


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

echo

for THIS_GEM in `cat couchdb/Gemfile |grep '^[ ]*gem' |awk '{print $2}' | sed -r -e "s/[',]//g"`; do
    echo "Installing gem $THIS_GEM..."
    if [ -n "$PRE" -a -n "`echo $THIS_GEM | egrep copperegg`" ]; then
        # install prerelease gems if "$PRE" is not null, but only for copperegg
        gem install --no-ri --no-rdoc $THIS_GEM --pre --source 'http://rubygems.org' >> $PKG_INST_OUT 2>&1
    else
        gem install --no-ri --no-rdoc $THIS_GEM --source 'http://rubygems.org' >> $PKG_INST_OUT 2>&1
    fi
    install_rc=$?
    if [ $install_rc -ne 0 ]; then
        echo
        echo "********************************************************"
        echo "********************************************************"
        echo "*** "
        echo "*** WARNING: gem $THIS_GEM did not install properly!"
        echo "*** Please contact support-uptimecm@idera.com if you are"
        echo "*** unable to run 'gem install $THIS_GEM' manually."
        echo "*** "
        echo "********************************************************"
        echo "********************************************************"
        echo
    fi
done


#
# create config.yml
#
echo
echo
echo "------------------------------------------------------------------"
echo
CONFIG_FILE="/usr/local/ucm/ucm-metrics/couchdb/config.yml"
AGENT_FILE="/usr/local/ucm/ucm-metrics/couchdb/couchdb.rb"
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

    # mysql
    if [ -n "$MONITOR_COUCHDB" ]; then
        setup_base_group "couchdb" "CouchDB"

        rc=1
        while [ $rc -ne 0 ]; do
            # loop with defaults until they get it right
            echo "Configuring first CouchDB server (required)"
            setup_couchdb "`hostname | sed 's/ /_/g'`-couchdb" "localhost" "5984"
            rc=$?
        done

        while true; do
            echo -n "Add another CouchDB server? [Yn] "
            read yn
            if [ -n "`echo $yn | egrep -io '^n'`" ]; then
                break
            fi
            setup_couchdb "" "" "5984"
        done

    fi
fi


chown -R $COPPEREGG_USER:$COPPEREGG_GROUP /usr/local/ucm/*

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
    echo "  nohup ruby $AGENT_FILE --config $CONFIG_FILE >/tmp/ucm-metrics.log 2>&1 &"
    echo
fi

echo
echo "Install complete!"
echo "If you have any questions, please contact support-uptimecm@idera.com"
