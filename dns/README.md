DNS Monitoring with Uptime Cloud Monitor
===========================

Example scripts to gather stats and metrics for your Domain entries and send to Uptime Cloud Monitor.

dns.rb
=============

Just add a few entries to a config.yml file, run the dns script, and
  - custom metric groups will be created,
  - DNS related metrics will be gathered and analyzed for your route entries ,
  - A custom dashboard will be generated, visible from the Dashboards tab, and
  - Gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and get started at <https://app.copperegg.com/login>

#Getting Started with the dns.rb Ruby script

##1. Install dependencies

This has been tested with ruby 2.3.0. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/dns

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your Uptime Cloud Monitor User API Key:  replace "YOUR\_APIKEY" with your API key, found in the settings tab of http://app.copperegg.com.
  - Add required details related to your domain, nameservers, expected response (match), timeout, etc.
  - Optionally, change your custom dashboard name, by replacing "DNS Monitoring".

Be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./dns.rb

You should see some output saying that metric groups and a dashboard has been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./dns.rb >/tmp/ucm-dns-metrics.log 2>&1 &

And it will run in the background, and log to /tmp/ucm-dns-metrics.log


##5. Enjoy your new DNS Monitoring Dashboard

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "DNS Monitoring" will appear in the left nav of the Dashboards tab.  Enjoy!

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from DNS Monitoring, just as simply as setting up all of your Uptime Cloud Monitor system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.


