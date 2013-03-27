Riak Monitoring with CopperEgg
===========================

Example scripts to gather stats and metrics from Riak, and send to CopperEgg.

Stats gathered are from suggested stats from Basho:

http://docs.basho.com/riak/latest/cookbooks/Statistics-and-Monitoring/
http://docs.basho.com/riak/latest/references/apis/http/HTTP-Status/

riak.rb
=============

Just add a few entries to a config.yml file, run the riak script, and
  - custom metric groups will be created,
  - Riak metrics will be gathered and analyzed from your Riak servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a CopperEgg account, you may create one at <https://copperegg.com/copperegg-signup/>

If you have a CopperEgg account, you may log in and get started at <https://app.copperegg.com/login>

#Getting Started with the riak.rb Ruby script

##1. Install dependencies

This has been tested with ruby 1.9.3. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/riak

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your CopperEgg User API Key:  replace "YOUR\_APIKEY" with your API key, found in the settings tab of http://app.copperegg.com.
  - Edit the URL to include the hostname of your Riak node.
  - Optionally, change your custom dashboard name, by replacing "Riak Dashboard".

You will need to enable the /stats/ function in your app.config (Riak config) by adding {riak_kv_stat,true} to the riak_kv section of your config, and making sure it has loaded that config (however you choose to do that).

Be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./riak.rb

You should see some output saying that metric groups and a dashboard has been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./riak.rb >/tmp/copperegg-riak.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-riak.log


##5. Enjoy your new Riak Dashboard

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "Riak Dashboard" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the Riak Dashboard which display data from any metric groups, including system metrics gathered using any of CopperEgg's services.

Have a look at the [CopperEgg Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from Riak, just as simply as setting up all of your CopperEgg system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

