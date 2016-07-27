#!/bin/bash

echo
echo "For yes/no questions, type 'y' for yes, 'n' for no."
echo "Or press Enter to use the default answer."

echo

# we send one service at a time from main installer script (reveal repo).
# and then this installer calls specific installer for that service (say couchdb)

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
    echo "Using this ruby : "
    echo "Ruby path = `which ruby 2>/dev/null`"
    echo "Ruby version = `ruby --version`"
    INSTALL_RVM=""
    RVM_TYPE="system"
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

# Add more services here and call its respective script
MONITOR_COUCHDB="`echo $MON_LIST | egrep -o 'couchdb'`"
MONITOR_POSTGRESQL="`echo $MON_LIST | egrep -o 'postgresql'`"

export COPPEREGG_USER COPPEREGG_GROUP
if [ -n "$MONITOR_COUCHDB" ]; then
    bash "couchdb/couchdb_installer.sh"
fi
if [ -n "$MONITOR_POSTGRESQL" ]; then
    bash "postgresql/postgresql_installer.sh"
fi

echo
echo "Install complete!"
echo "If you have any questions, please contact support-uptimecm@idera.com"
