Cassandra Monitoring with Uptime Cloud Monitor
===========================

A Ruby script to gather performance metrics from Cassandra, and send them to Uptime Cloud Monitor.


cassandra.rb
=============

Just add a few entries to a config.yml file, run the  script, and
  - custom metric groups will be created,
  - cassandra metrics will be gathered and analyzed from your cassandra servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and get started at <https://app.copperegg.com/login>

##Getting Started with the cassandra.rb Ruby script

##1. Install dependencies

This plugin requires nodetool which comes in package with cassandra setup. Ensure that cassandra is installed on the server where you intend to run this script. The script is tested for cassandra 2.2 and above.

This has been tested with ruby 1.9.3 on Ubuntu 14.04. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/cassandra

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your Uptime Cloud Monitor User API Key:  replace 'YOUR_APIKEY' with your API key, found in the settings tab of http://app.copperegg.com.

  - You will find one defined service : 'cassandra'. The cassandra service monitors all of the cassandra servers specified in the config.yml. It must be edited to specify the correct cassandra server hostname, port, username and password.

  - A custom dashboard will be created to display these metrics for all databases. The name of the custom dashboard will be cassandra. You may optionally choose a different dashboard name.

When editing the config.yml file, be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./cassandra.rb

You should see some output saying that metric groups and dashboards have been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./cassandra.rb >/tmp/copperegg-cassandra.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-cassandra.log


###5. Enjoy your new cassandra Dashboards

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "cassandra" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the cassandra Dashboard which display data from any metric groups, including system metrics gathered using any of Uptime Cloud Monitor's services. We recommend that you also install the Uptime Cloud Monitor collector on you cassandra server, so that you can correlate cassandra performance with the underlying system metrics.


Have a look at the [Uptime Cloud Monitor Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from cassandra, just as simply as setting up all of your Uptime Cloud Monitor system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

