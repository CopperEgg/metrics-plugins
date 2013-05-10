MongoDB Monitoring with CopperEgg
===========================

Example scripts to gather stats and metrics from MongoDB, and send to CopperEgg.


mongodb.rb
=============

Just add a few entries to a config.yml file, run the mongodb script, and
  - custom metric groups will be created,
  - mongodb metrics will be gathered and analyzed from your mongodb servers,
  - a custom dashboard will be generated, visible from the Dashboards tab, and
  - the gathered metrics will be displayed in a series of widgets on your new dashboard.

If you do not have a CopperEgg account, you may create one at <https://copperegg.com/copperegg-signup/>

If you have a CopperEgg account, you may log in and get started at <https://app.copperegg.com/login>

#Getting Started with the mongodb.rb Ruby script

##1. Install dependencies

This has been tested with ruby 1.9.3. You will need to install and set up Ruby on your system, you can find documentation on how to do that on the Ruby site, or anywhere else Google takes you.

##2. Download and configure the agent

    git clone git://github.com/CopperEgg/metrics-plugins.git
    cd metrics-plugins/mongodb

Copy the example config into config.yml, and edit with your favorite editor:

  - Enter your CopperEgg User API Key:  replace 'YOUR_APIKEY' with your API key, found in the settings tab of http://app.copperegg.com.
  - You will find two services, 'mongo_dbadmin' and 'mongodb'
  - The mongo_dbadmin service monitors the privelaged 'admin' database; it must be edited to include the correct mongodb server hostname, port and username / password of the mogodb admin.
    The database 'admin' should not be changed; you can apply any name you choose for the server 'name.'
  - The mongodb service monitors the individual database metrics; it should have the same server name, hostname and port as the server defined in the mongo_dbadmin.
    For each database you wish to monitor, add a 'database section' containing the database name, and the appropriate username / password of someone permitted to view these meterics.
    
    *** Note that two dashboards will be created by default. One 'Admin' dashboard, and one 'Database' dashboard. 

  - Optionally, change your dashboard names; we do recommend that you give these dashboards different names.

Be sure to keep the same spacing supplied in the original file.

##3. Bundle and Install gems

Ensure that current ruby gems are installed.

    bundle install

##4. Run the agent

    ruby ./mongodb.rb

You should see some output saying that metric groups and dashboards have been created, and services are being monitored.

To run the process in the background, you may use:

    nohup ruby ./mongodb.rb >/tmp/copperegg-mongodb.log 2>&1 &

And it will run in the background, and log to /tmp/copperegg-mongodb.log


##5. Enjoy your new mongoDB Dashboards

It may take up to a minute for the dashboard to automatically appear, once created.
After a minute or a page refresh, "MongoDB Databases" and MongoDB Admin" will appear in the left nav of the Dashboards tab.  Enjoy!

Note that you can add widgets to the Mongodb Dashboard which display data from any metric groups, including system metrics gathered using any of CopperEgg's services.

Have a look at the [CopperEgg Demo site](https://app.copperegg.com/demo), to see more ideas on how to customize and optimize your cloud infrastructure and application monitoring.

Don't forget that you can set alerts and notifications based on the custom metrics being gathered from mongodb, just as simply as setting up all of your CopperEgg system and website monitoring alerts. Simply go to the Issues tab, and navigate to Configure Alerts.

