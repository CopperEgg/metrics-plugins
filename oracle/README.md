Oracle Monitoring with Uptime Cloud Monitor
===========================

A Ruby script to gather performance metrics from Oracle, and send them to Uptime Cloud Monitor.


oracle.rb
=============

Just add a few entries to a config.yml file, run the  script, and
  - custom metric groups will be created,
  - oracle metrics will be gathered and analyzed from your oracle servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and get started at <https://app.copperegg.com/login>

##Getting Started with the oracle.rb Ruby script

##1. Install dependencies

This plugin requires the 'oci8' gem, AKA the ruby-oci8 gem. It will be installed during the bundle process.

This has been tested with ruby 1.9.3. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.
Oracle Instant Client/Full Client setup needs be present on the server where script is running. SqlPlus will be installed on the server
Full client : http://www.rubydoc.info/github/kubo/ruby-oci8/file/docs/install-full-client.md
Instant Client : http://www.rubydoc.info/github/kubo/ruby-oci8/file/docs/install-instant-client.md
LD_LIBRARY_PATH and ORACLE_HOME variables must be set in order to make sqlplus work.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/oracle

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your Uptime Cloud Monitor User API Key:  replace 'YOUR_APIKEY' with your API key, found in the settings tab of http://app.copperegg.com.

  - You will find one defined service : 'oracle'. The oracle service monitors all of the oracle databases specified in the config.yml. It must be edited to specify the correct oracle server hostname, port and username / password of each of the server specified.

  - A custom dashboard will be created to display these metrics for all databases. The name of the custom dashboard will be Oracle Dashboard. You may optionally choose a different dashboard name.

When editing the config.yml file, be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./oracle.rb

You should see some output saying that metric groups and dashboards have been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./oracle.rb > /tmp/revealmetrics_oracle.log 2>&1 &

And it will run in the background, and log to /tmp/revealmetrics_oracle.log


###5. Enjoy your new Oracle Dashboards

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "Oracle Dashboard" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the Oracle Dashboard which display data from any metric groups, including system metrics gathered using any of Uptime Cloud Monitor's services. We recommend that you also install the Uptime Cloud Monitor collector on you Oracle server, so that you can correlate Oracle performance with the underlying system metrics.


Have a look at the [Uptime Cloud Monitor Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from oracle, just as simply as setting up all of your Uptime Cloud Monitor system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

