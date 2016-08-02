PostgreSQL Monitoring with Uptime Cloud Monitor
===========================

A Ruby script to gather performance metrics from PostgreSQL, and send them to Uptime Cloud Monitor.


postgresql.rb
=============

Just add a few entries to a config.yml file, run the  script, and
  - custom metric groups will be created,
  - postgresql metrics will be gathered and analyzed from your postgresql servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and get started at <https://app.copperegg.com/login>

##Getting Started with the postgresql.rb Ruby script

##1. Install dependencies

This plugin requires the 'pg' gem, AKA the ruby-pg gem. It will be installed during the bundle process.

This has been tested with ruby 1.9.3 and with Ruby-1.8.7 on Ubuntu 12.04. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/postgresql

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your Uptime Cloud Monitor User API Key:  replace 'YOUR_APIKEY' with your API key, found in the settings tab of http://app.copperegg.com.

  - You will find one defined service : 'postgresql'. The postgresql service monitors all of the postgresql databases specified in the config.yml. It must be edited to specify the correct postgresql server hostname, port and username / password of each of the databases specified.

  - A custom dashboard will be created to display these metrics for all databases. The name of the custom dashboard will be PostgreSQL. You may optionally choose a different dashboard name.

When editing the config.yml file, be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./postgresql.rb

You should see some output saying that metric groups and dashboards have been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./postgresql.rb >/tmp/copperegg-postgresql.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-postgresql.log


###5. Enjoy your new PostgreSQL Dashboards

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "PostgreSQL" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the PostgreSQL Dashboard which display data from any metric groups, including system metrics gathered using any of Uptime Cloud Monitor's services. We recommend that you also install the Uptime Cloud Monitor collector on you PostgreSQL server, so that you can correlate PostgreSQL performance with the underlying system metrics.


Have a look at the [Uptime Cloud Monitor Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from postgresql, just as simply as setting up all of your Uptime Cloud Monitor system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

