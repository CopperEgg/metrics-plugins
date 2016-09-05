revealmetrics-example-agent
===========================

Example agent for use with Uptime Cloud Monitor RevealMetrics.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and use RevealMetrics at <https://app.copperegg.com/login>


# Getting Started with RevealMetrics Ruby Agent

## 1. Install dependencies ruby and mysql-dev

This has been tested with both ruby 1.8.7 and 1.9.3.  We recommend 1.9.3+ if it's easy,
but many operating systems still default to 1.8.7, so we'll use that here.

On newer Debian/Ubuntu, run:

    sudo apt-get -y install ruby rubygems libopenssl-ruby unzip

If you need to monitor mysql, run this as well:

    sudo apt-get -y install ruby-dev libmysqld-dev build-essential

On RedHat/Fedora/CentOS/Amazon Linux, run:

    sudo yum install -y ruby rubygems mysql-devel


## 2. Download and configure the agent

Download the [revealmetrics-example-agent.zip](https://github.com/CopperEgg/revealmetrics-example-agent/archive/master.tar.gz)
file \([hosted at github](https://github.com/CopperEgg/revealmetrics-example-agent)\) on a Linux or Mac OSX system:

    cd ~; wget https://github.com/CopperEgg/revealmetrics-example-agent/archive/master.tar.gz

If needed, rename the downloaded file to have the correct extension:

    mv -f master master.tar.gz

Unzip the archive and enter the directory:

    tar -xvzf master.tar.gz; cd revealmetrics-example-agent-master

Copy the example config into config.yml, and edit with your favorite editor:

    cp config-example.yml config.yml; nano config.yml

Make sure to replace "YOUR\_APIKEY" with your api key, found in the settings tab of app.copperegg.com.
Remove any sections that you do not wish to monitor, and edit server settings accordingly.
Be sure to keep the same spacing supplied in the original file.


## 3. Install gems

Ensure that the ruby gems are installed.  Do not use the "--without=mysql" flag if you want to monitor mysql:

    gem install bundler; bundle install --without=mysql

If installing bundler fails with the error "bundler requires RubyGems version >= 1.3.6",
try running this command and then rerunning the bundle command above:

    gem install rubygems-update; sudo /var/lib/gems/1.*/bin/update_rubygems

If the bundle command still fails, run this \(and omit "redis" and/or "mysql2" if desired\):

    gem install json_pure copperegg redis mysql2


##4. Run the agent

Run the agent in a terminal:

    ruby ./copperegg-agent.rb

You should see some output saying that dashboards are created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./copperegg-agent.rb >/tmp/copperegg-agent.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-agent.log


##5. Enjoy your new Dashboards

It may take up to a minute for the dashboards to automatically appear, once they are created.
After a minute or a page refresh, they will appear in the left nav of the RevealMetrics tab.  Enjoy!

