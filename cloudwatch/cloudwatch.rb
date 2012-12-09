#!/usr/bin/env ruby
#
# Copyright 2012 CopperEgg Corporation.  All rights reserved.
#

require 'getoptlong'
require 'copperegg'
require 'json'
require 'yaml'
require 'aws'

####################################################################

def help
  puts "usage: $0 args"
  puts "Examples:"
  puts "  -c config.yml"
  puts "  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)"
  puts "  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])"
end

def interruptible_sleep(seconds)
  seconds.times {|i| sleep 1 if !@interrupted}
end

####################################################################

# get options
opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

config_file = "config.yml"
apikey = nil
@apihost = nil
@debug = nil
@freq = 60  # update frequency in seconds
@interupted = false

# Options and examples:
opts.each do |opt, arg|
  case opt
  when '--help'
    help
    exit
  when '--debug'
    @debug = true
  when '--config'
    config_file = arg
  when '--apikey'
    apikey = arg
  when '--apihost'
    @apihost = arg
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && apikey.nil?
  else
    puts "You have no copperegg entry in your config.yml!"
    puts "Edit your config.yml and restart."
    exit
  end
else
  puts "You need to have a config.yml to set your AWS credentials"
  exit
end

if apikey.nil?
  puts "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

####################################################################
def fetch_cloudwatch_stats(namespace, metric_name, stats, dimensions)

  cl = AWS::CloudWatch::Client.new()

  begin
    stats = cl.get_metric_statistics( :namespace => namespace,
                                    :metric_name => metric_name,
                                    :dimensions => dimensions,
                                    :start_time => (Time.now - 13200).to_time.iso8601,
                                    :end_time => Time.now.utc.iso8601,
                                    :period => 60,
                                    :statistics => stats)
  rescue Exception => e
    puts "Error getting cloudwatch stats: #{metric_name} [skipping]"
    stats = nil
  end
  return stats
end

def monitor_aws(apikey)
  puts "#######################################"
  puts " Begin monitoring AWS"

  AWS.config({
    :access_key_id => @config["aws"]["access_key_id"],
    :secret_access_key => @config["aws"]["secret_access_key"],
    :max_retries => 2,
  })

  rm = CopperEgg::Metrics.new(apikey, @apihost)

  while !@interupted do
    return if @interrupted

    m = AWS::CloudWatch::Metric.new("AWS/ELB", "RequestCount")
    cl = AWS::CloudWatch::Client.new()

    rds = AWS::RDS.new()
    dbs = rds.db_instances()
    dbs.each do |db|
      metrics = {}
      instance = db.db_instance_id

      stats = fetch_cloudwatch_stats("AWS/RDS", "DiskQueueDepth", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
      if stats != nil && stats[:datapoints].length > 0
        puts "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]} queue depth" if @debug
        metrics["DiskQueueDepth"] = stats[:datapoints][0][:average].to_i
      end

      stats = fetch_cloudwatch_stats("AWS/RDS", "ReadLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
      if stats != nil && stats[:datapoints].length > 0
        puts "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} read latency (ms)" if @debug
        metrics["ReadLatency"] = stats[:datapoints][0][:average]*1000
      end

      stats = fetch_cloudwatch_stats("AWS/RDS", "WriteLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
      if stats != nil && stats[:datapoints].length > 0
        puts "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} write latency (ms)" if @debug
        metrics["WriteLatency"] = stats[:datapoints][0][:average]*1000
      end

      rm.store_sample("aws_rds", instance, Time.now.to_i, metrics)
    end


    elb = AWS::ELB.new()
    lbs = elb.load_balancers()
    lbs.each do |lb|
      metrics = {}
      instance = lb.name

      stats = fetch_cloudwatch_stats("AWS/ELB", "Latency", ['Average'], [{:name=>"LoadBalancerName", :value=>lb.name}])
      if stats != nil && stats[:datapoints].length > 0
        puts "#{lb.name} : Latency : #{stats[:datapoints][0][:average]*1000} ms" if @debug
        metrics["Latency"] = stats[:datapoints][0][:average]*1000
      end

      stats = fetch_cloudwatch_stats("AWS/ELB", "RequestCount", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
      if stats != nil && stats[:datapoints].length > 0
        puts "#{lb.name} : RequestCount : #{stats[:datapoints][0][:sum].to_i} requests" if @debug
        metrics["RequestCount"] = stats[:datapoints][0][:sum].to_i
      end

      stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_2XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
      if stats != nil && stats[:datapoints].length > 0
        puts "#{lb.name} : HTTPCode_Backend_2XX : #{stats[:datapoints][0][:sum].to_i} Successes" if @debug
        metrics["HTTPCode_Backend_2XX"] = stats[:datapoints][0][:sum].to_i
      end

      stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_5XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
      if stats != nil && stats[:datapoints].length > 0
        puts "#{lb.name} : HTTPCode_Backend_5XX : #{stats[:datapoints][0][:sum].to_i} Errors" if @debug
        metrics["HTTPCode_Backend_5XX"] = stats[:datapoints][0][:sum].to_i
      end

      rm.store_sample("aws_elb", instance, Time.now.to_i, metrics)
    end

    metrics = {}

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["Total"] = stats[:datapoints][-1][:maximum].to_f
    end


    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonEC2"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["EC2"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRDS"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["RDS"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonS3"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["S3"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRoute53"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["Route53"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"SimpleDB"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["SimpleDB"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonSNS"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["SNS"] = stats[:datapoints][-1][:maximum].to_f
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AWSDataTransfer"},
                                                      {:name=>"Currency", :value=>"USD"}])
    if stats != nil && stats[:datapoints].length > 0
      puts stats[:datapoints][-1][:maximum].to_f if @debug
      metrics["DataTransfer"] = stats[:datapoints][-1][:maximum].to_f
    end
    rm.store_sample("aws_billing", "aws_charges", Time.now.to_i, metrics)


    ec2 = AWS::EC2.new()
    stopped = 0
    running = 0
    pending = 0
    shutting_down = 0
    terminated = 0
    stopping = 0

    begin
    instances = ec2.instances
    instances.each do |instance|
      status = instance.status
      stopped += 1 if status == :stopped
      running += 1 if status == :running
      pending += 1 if status == :pending
      shutting_down += 1 if status == :shutting_down
      terminated += 1 if status == :terminated
      stopping += 1 if status == :stopping
    end

    metrics = {}
    metrics["Running"]                = running.to_i
    metrics["Stopped"]                = stopped.to_i
    metrics["Pending"]                = pending.to_i
    metrics["Shutting_Down"]          = shutting_down.to_i
    metrics["Terminated"]             = terminated.to_i
    metrics["Stopping"]               = stopping.to_i
    rm.store_sample("aws_ec2", "ec2_instances", Time.now.to_i, metrics)
    rescue
    end

    interruptible_sleep @freq
  end
end


def create_aws_metric_groups(apikey)
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)

  # no metric group found - create one
  puts "Creating AWS metric groups"

  groupcfg = {}
  groupcfg["name"] = "aws_elb"
  groupcfg["label"] = "AWS - ELB"
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_counter", "name"=>"RequestCount",           "unit"=>"Requests"},
                         {"type"=>"ce_gauge_f", "name"=>"Latency",                "unit"=>"ms"},
                         {"type"=>"ce_gauge",   "name"=>"HTTPCode_Backend_2XX",   "unit"=>"Responses"},
                         {"type"=>"ce_gauge",   "name"=>"HTTPCode_Backend_5XX",   "unit"=>"Responses"}
                       ]
  res = ce_metrics.create_metric_group(groupcfg["name"], groupcfg)



  groupcfg = {}
  groupcfg["name"] = "aws_rds"
  groupcfg["label"] = "AWS - RDS"
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge_f", "name"=>"DiskQueueDepth"},
                         {"type"=>"ce_gauge_f", "name"=>"ReadLatency",            "unit"=>"ms"},
                         {"type"=>"ce_gauge_f", "name"=>"WriteLatency",           "unit"=>"ms"}
                       ]
  res = ce_metrics.create_metric_group(groupcfg["name"], groupcfg)



  groupcfg = {}
  groupcfg["name"] = "aws_ec2"
  groupcfg["label"] = "AWS - EC2"
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge",   "name"=>"Running",                "unit"=>"Instances"},
                         {"type"=>"ce_gauge",   "name"=>"Stopped",                "unit"=>"Instances"},
                         {"type"=>"ce_gauge",   "name"=>"Pending",                "unit"=>"Instances"},
                         {"type"=>"ce_gauge",   "name"=>"Shutting_Down",          "unit"=>"Instances"},
                         {"type"=>"ce_gauge",   "name"=>"Terminated",             "unit"=>"Instances"},
                         {"type"=>"ce_gauge",   "name"=>"Stopping",               "unit"=>"Instances"}
                       ]
  res = ce_metrics.create_metric_group(groupcfg["name"], groupcfg)



  groupcfg = {}
  groupcfg["name"] = "aws_billing"
  groupcfg["label"] = "AWS - Billing"
  groupcfg["frequency"] = @freq
  groupcfg["metrics"] = [{"type"=>"ce_gauge_f", "name"=>"Total",        "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"EC2",          "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"RDS",          "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"S3",           "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"Route53",      "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"SimpleDB",     "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"SNS",          "unit"=>"USD"},
                         {"type"=>"ce_gauge_f", "name"=>"DataTransfer", "unit"=>"USD"}
                       ]
  res = ce_metrics.create_metric_group(groupcfg["name"], groupcfg)

end

def create_aws_dashboard(apikey)

  puts "Creating new AWS Dashboard"
  ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)
return
  # Configure a dashboard:
  dashcfg = {}
  dashcfg["name"] = "AWS Dashboard"
  dashcfg["data"] = {}

  widgets = {}

  # Create a widget
  widgetcfg = {}
  widgetcfg["type"] = "metric"
  widgetcfg["style"] = "both"
  widgetcfg["metric"] = [group_name, "19", "keys"]
  widgetcfg["match"] = "select"
  widgetcfg["match_param"] = server
  widgets["0"] = widgetcfg.dup

  widgetcfg["type"] = "metric"
  widgetcfg["style"] = "both"
  widgetcfg["metric"] = [group_name, "11", "total_connections_received"]
  widgetcfg["match"] = "select"
  widgetcfg["match_param"] = server
  widgets["1"] = widgetcfg.dup

  widgetcfg["type"] = "metric"
  widgetcfg["style"] = "both"
  widgetcfg["metric"] = [group_name, "3", "connected_clients"]
  widgetcfg["match"] = "select"
  widgetcfg["match_param"] = server
  widgets["2"] = widgetcfg.dup

  widgetcfg["type"] = "metric"
  widgetcfg["style"] = "both"
  widgetcfg["metric"] = [group_name, "6", "used_memory"]
  widgetcfg["match"] = "select"
  widgetcfg["match_param"] = server
  widgets["3"] = widgetcfg.dup

  widgetcfg["type"] = "metric"
  widgetcfg["style"] = "both"
  widgetcfg["metric"] = [group_name, "12", "total_commands_processed"]
  widgetcfg["match"] = "select"
  widgetcfg["match_param"] = server
  widgets["4"] = widgetcfg.dup

  # Add the widgets to the dashboard:
  dashcfg["data"]["widgets"] = widgets

  # Set the order we want on the dashboard:
  dashcfg["data"]["order"] = widgets.keys

  # Create the dashboard:
  res = ce_metrics.create_dashboard(dashcfg)
end


####################################################################


# metric group check
puts "Checking for existence of metric group for AWS"
ce_metrics = CopperEgg::Metrics.new(apikey, @apihost)
mgroup = ce_metrics.metric_group("aws_ec2")

if !mgroup.nil?
  # no metric group found - create one
  create_aws_metric_groups(apikey)
end

# Check for dashboard:
puts "Checking for existence of AWS Dashboard"
dashboard = ce_metrics.dashboard("AWS Dashboard")

if dashboard.nil?
  # no dashboard found - create one
  create_aws_dashboard(apikey)
end

monitor_aws(apikey)



