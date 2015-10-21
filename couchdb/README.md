CouchDB Monitoring with Uptime Cloud Monitor
===========================

Example scripts to gather stats and metrics from CouchDB, and send to Uptime Cloud Monitor.

couchdb.rb
=============

Just add a few entries to a config.yml file, run the couchdb script, and
  - custom metric groups will be created,
  - CouchDB metrics will be gathered and analyzed from your CouchDB servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a Uptime Cloud Monitor account, you may create one at <https://www.idera.com/infrastructure-monitoring-as-a-service/freetrialsubscriptionform>

If you have a Uptime Cloud Monitor account, you may log in and get started at <https://app.copperegg.com/login>

#Getting Started with the couchdb.rb Ruby script

##1. Install dependencies

This has been tested with ruby 1.9.3. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/couchdb

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your Uptime Cloud Monitor User API Key:  replace "YOUR\_APIKEY" with your API key, found in the settings tab of http://app.copperegg.com.
  - Edit the URL to include the hostname of your CouchDB server.
  - Optionally, change your custom dashboard name, by replacing "CouchDB Dashboard".

Be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./couchdb.rb

You should see some output saying that metric groups and a dashboard has been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./couchdb.rb >/tmp/copperegg-couchdb.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-couchdb.log


##5. Enjoy your new CouchDB Dashboard

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "CouchDB Dashboard" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the CouchDB Dashboard which display data from any metric groups, including system metrics gathered using any of Uptime Cloud Monitor's services.

Have a look at the [Uptime Cloud Monitor Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from CouchDB, just as simply as setting up all of your Uptime Cloud Monitor system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

##Addendum.

Added the ability to do basic authentication for CouchDB, this is optional, but the example-configuration has the correct configuration.
