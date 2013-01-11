metrics-plugins
===========================

Example scripts, tools, etc for RevealMetrics.

cloudwatch.rb
=============

The first script included in this repo is cloudwatch.rb. Just add a few entries to a config.yml file, run the cloudwatch script, and
  - custom metric groups will be created,
  - AWS cloudwatch metrics will be gathered and analyzed from your ELB, RDS, EC2 services, in addition to billing information for your AWS services,
  - a custom dashboard will be generated, visible from the RevealMetrics tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

The script gathers quite a bit of information from AWS Cloudwatch; the example script only creates widgets for a subset of the data that is gathered.

If you do not have a CopperEgg account, you may create one at <https://copperegg.com/copperegg-signup/>

If you have a CopperEgg account, you may log in and use RevealMetrics at <https://app.copperegg.com/login>

#Getting Started with the cloudwatch.rb Ruby script

##1. Install dependencies ruby and mysql-dev

This has been tested with both ruby 1.8.7 and 1.9.3.  We recommend 1.9.3+ if it's easy,
but many operating systems still default to 1.8.7, so we'll use that here.
Note that the ruby developer packages need to be installed, as described below. The reason for this is the aws-sdk gem requires nokogiri; nokogiri will attempt to build native extensions for the OS on which it is being installed.
If you have any difficulties with the installation of Nokogiri, please refer to 'Installing Nokogiri' here: <http://nokogiri.org/tutorials/installing_nokogiri.html>


On newer Debian/Ubuntu, run:

    sudo apt-get -y install ruby rubygems ruby-bundler libopenssl-ruby unzip  # needed for ruby
    sudo apt-get -y install ruby1.8-dev ri1.8 rdoc1.8 irb1.8  # ruby dev packages
    sudo apt-get -y install libreadline-ruby1.8 libruby1.8  # ruby libs
    sudo apt-get -y install libxslt-dev libxml2-dev build-essential # dependencies for aws gem

On RedHat/Fedora/CentOS/Amazon Linux, run:

    sudo yum install -y ruby rubygems
    sudo yum install -y gcc g++ make automake autoconf curl-devel openssl-devel zlib-devel httpd-devel
    sudo yum install -y ruby-rdoc ruby-devel libxml2 libxml2-devel libxslt libxslt-devel

On Mac OS X, we highly recommend installing RVM, the Ruby Version Manager. The most simple way to install and use RVM is to install JewelryBox, the official RVM GUI, found here: <http://unfiniti.com/software/mac/jewelrybox>
RVM can also be used from the command line; please see the RVM website: <https://rvm.io>

##2. Download and configure the agent

    sudo apt-get -y install git
    mkdir ~/git
    cd ~/git
    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins

Copy the example config into config.yml, and edit with your favorite editor:

    cp config-example.yml config.yml
    nano config.yml

  - Enter your CopperEgg User API Key:  replace "YOUR\_APIKEY" with your api key, found in the settings tab of app.copperegg.com.
  - Enter your AWS access\_key\_id: replace "YourAWSAccessKey" with your aws access key id.
  - Enter your AWS secret\_access\_key: replace "SuperSecretAWSKeyGoesHere" with your aws secret access key.
  - Optionally, change your custom dashboard name, by replacing "AWS Monitoring".
  - Optionally, remove any of the aws services that you do NOT want to monitor from the list:
    - elb
    - rds
    - ec2
    - billing

Be sure to keep the same spacing supplied in the original file.
And of course, save the file before closing your editor.


##3. Bundle and Install gems

Ensure that current ruby gems are installed.

From the metrics-plugins directory:
    gem install nokogiri --no-ri --no-rdoc
    gem install aws-sdk --no-ri --no-rdoc
    gem install copperegg -v 0.5.3 --no-ri --no-rdoc

##4. Run the agent

From the metrics-plugins directory:

    ruby ./cloudwatch/cloudwatch.rb

You should see some output saying that metric groups and a dashboard has been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./cloudwatch/cloudwatch.rb >/tmp/copperegg-cloudwatch.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-cloudwatch.log


##5. Enjoy your new AWS Dashboard

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "AWS Monitoring" will appear in the left nav of the RevealMetrics tab.  Enjoy!

Note that you can add widgets to the AWS dashboard which display data from any metric groups, including system metrics gathered using the CopperEgg collector, and website monitoring metrics gathered by CopperEgg RevealUptime.

Have a look at the CopperEgg Demo site, to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring here: <https://app.copperegg.com/demo>

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from AWS, just as simply as setting up all of your CopperEgg system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.



