#!/usr/bin/env ruby
#
# Copyright 2012 CopperEgg Corporation.  All rights reserved.
#

require 'rubygems'
require 'getoptlong'
require 'copperegg'
require 'json'
require 'yaml'
require 'aws-sdk'

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

def sleep_until(seconds_divisor)
  end_time = ((Time.now.to_i / seconds_divisor) * seconds_divisor) + seconds_divisor
  while @interrupted && (Time.now.to_i < end_time)
    sleep 1
  end
end


TIME_STRING='%Y/%m/%d %H:%M:%S'
##########
# Used to prefix the log message with a date.
def log(str)
  begin
    str.split("\n").each do |str|
      puts "#{Time.now.strftime(TIME_STRING)} pid:#{Process.pid}> #{str}"
    end
    $stdout.flush
  rescue Exception => e
    # do nothing -- just catches unimportant errors when we kill the process
    # and it's in the middle of logging or flushing.
  end
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
@debug = false
@freq = 60  # update frequency in seconds
@interupted = false
@elb = false
@rds = false
@ec2 = false
@billing = false

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
    CopperEgg::Api.apikey = arg
  when '--apihost'
    CopperEgg::Api.host = arg
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    CopperEgg::Api.apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && apikey.nil?
  else
    log "You have no copperegg entry in your config.yml!"
    log "Edit your config.yml and restart."
    exit
  end
  if !@config["aws"].nil?
    @services = @config['aws']['services']
    log "Reading config: services are " + @services.to_s + "\n"
  end
else
  log "You need to have a config.yml to set your AWS credentials"
  exit
end

if CopperEgg::Api.apikey.nil?
  log "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

if @services.length == 0
  log "No AWS services listed in the config file."
  log "Nothing will be monitored!"
  exit
end


  AWS.config({
    :access_key_id => @config["aws"]["access_key_id"],
    :secret_access_key => @config["aws"]["secret_access_key"],
    :max_retries => 2,
  })


####################################################################
def fetch_cloudwatch_stats(namespace, metric_name, stats, dimensions, start_time=(Time.now - @freq).iso8601)

  cl = AWS::CloudWatch::Client.new()

  begin
    stats = cl.get_metric_statistics( :namespace => namespace,
                                    :metric_name => metric_name,
                                    :dimensions => dimensions,
                                    :start_time => start_time,
                                    :end_time => Time.now.utc.iso8601,
                                    :period => @freq,
                                    :statistics => stats)
  rescue Exception => e
    log "Error getting cloudwatch stats: #{metric_name} [skipping]"
    stats = nil
  end
  return stats
end

def monitor_aws()
  log "#######################################"
  log " Begin monitoring AWS"

  while !@interupted do
    return if @interrupted

    #m = AWS::CloudWatch::Metric.new("AWS/ELB", "RequestCount")
    cl = AWS::CloudWatch::Client.new()

    if @rds == true
      rds = AWS::RDS.new()

      dbs = rds.db_instances()
      dbs.each do |db|
        metrics = {}
        instance = db.db_instance_id

        stats = fetch_cloudwatch_stats("AWS/RDS", "DiskQueueDepth", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
        if stats != nil && stats[:datapoints].length > 0
          log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]} queue depth" if @debug
          metrics["DiskQueueDepth"] = stats[:datapoints][0][:average].to_i
        else
          metrics["DiskQueueDepth"] = 0
        end

        stats = fetch_cloudwatch_stats("AWS/RDS", "ReadLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
        if stats != nil && stats[:datapoints].length > 0
          log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} read latency (ms)" if @debug
          metrics["ReadLatency"] = stats[:datapoints][0][:average]*1000
        end

        stats = fetch_cloudwatch_stats("AWS/RDS", "WriteLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}])
        if stats != nil && stats[:datapoints].length > 0
          log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} write latency (ms)" if @debug
          metrics["WriteLatency"] = stats[:datapoints][0][:average]*1000
        end

        group_name = @config["rds"]["group_name"]
        log "rds: #{group_name} - #{instance} - #{metrics}" if @debug
        CopperEgg::MetricSample.save(group_name, instance, Time.now.to_i, metrics)
      end
    end

    if @elb == true
      elb = AWS::ELB.new()

      lbs = elb.load_balancers()
      lbs.each do |lb|
        metrics = {}
        instance = lb.name

        stats = fetch_cloudwatch_stats("AWS/ELB", "Latency", ['Average'], [{:name=>"LoadBalancerName", :value=>lb.name}])
        if stats != nil && stats[:datapoints].length > 0
          log "#{lb.name} : Latency : #{stats[:datapoints][0][:average]*1000} ms" if @debug
          metrics["Latency"] = stats[:datapoints][0][:average]*1000
        end

        stats = fetch_cloudwatch_stats("AWS/ELB", "RequestCount", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
        if stats != nil && stats[:datapoints].length > 0
          log "#{lb.name} : RequestCount : #{stats[:datapoints][0][:sum].to_i} requests" if @debug
          metrics["RequestCount"] = stats[:datapoints][0][:sum].to_i
        else
          metrics["RequestCount"] = 0
        end

        stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_2XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
        if stats != nil && stats[:datapoints].length > 0
          log "#{lb.name} : HTTPCode_Backend_2XX : #{stats[:datapoints][0][:sum].to_i} Successes" if @debug
          metrics["HTTPCode_Backend_2XX"] = stats[:datapoints][0][:sum].to_i
        else
          metrics["HTTPCode_Backend_2XX"] = 0
        end

        stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_5XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}])
        if stats != nil && stats[:datapoints].length > 0
          log "#{lb.name} : HTTPCode_Backend_5XX : #{stats[:datapoints][0][:sum].to_i} Errors" if @debug
          metrics["HTTPCode_Backend_5XX"] = stats[:datapoints][0][:sum].to_i
        else
          metrics["HTTPCode_Backend_5XX"] = 0
        end

        group_name = @config["elb"]["group_name"]
        log "elb: #{group_name} - #{instance} - #{metrics}" if @debug
        CopperEgg::MetricSample.save(group_name, instance, Time.now.to_i, metrics)
      end
    end

    if @billing == true
      metrics = {}

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["Total"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["Total"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonEC2"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats.datapoints.length > 0
        log stats.datapoints[-1].maximum.to_f if @debug
        metrics["EC2"] = stats.datapoints[-1].maximum.to_f
      else
        metrics["EC2"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRDS"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["RDS"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["RDS"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonS3"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["S3"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["S3"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRoute53"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["Route53"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["Route53"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"SimpleDB"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["SimpleDB"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["SimpleDB"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonSNS"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["SNS"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["SNS"] = 0.0
      end

      stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AWSDataTransfer"},
                                                        {:name=>"Currency", :value=>"USD"}], (Time.now - (@freq*720)).iso8601)
      if stats != nil && stats[:datapoints].length > 0
        log stats[:datapoints][-1][:maximum].to_f if @debug
        metrics["DataTransfer"] = stats[:datapoints][-1][:maximum].to_f
      else
        metrics["DataTransfer"] = 0.0
      end

      group_name = @config["billing"]["group_name"]
      log "billing: #{group_name} - aws_charges - #{metrics}" if @debug
      CopperEgg::MetricSample.save(group_name, "aws_charges", Time.now.to_i, metrics)
    end

    if @ec2 == true
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
          status = instance.status.to_s
          stopped += 1 if status == 'stopped'
          running += 1 if status == 'running'
          pending += 1 if status == 'pending'
          shutting_down += 1 if status == 'shutting_down'
          terminated += 1 if status == 'terminated'
          stopping += 1 if status == 'stopping'
        end

        metrics = {}
        metrics["Running"]                = running.to_i
        metrics["Stopped"]                = stopped.to_i
        metrics["Pending"]                = pending.to_i
        metrics["Shutting_down"]          = shutting_down.to_i
        metrics["Terminated"]             = terminated.to_i
        metrics["Stopping"]               = stopping.to_i

        group_name = @config["ec2"]["group_name"]
        log "ec2: #{group_name} - ec2_instances - #{metrics}" if @debug
        CopperEgg::MetricSample.save(group_name, "ec2_instances", Time.now.to_i, metrics)
      rescue Exception => e
        p e
      end
    end
    sleep_until @freq
  end
end

def ensure_elb_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating ELB metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating ELB metric group"
    metric_group.frequency = @freq
    #metric_group.is_hidden = false
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge",   :name => "RequestCount",         :unit => "Requests"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "Latency",              :unit => "ms"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "HTTPCode_Backend_2XX", :unit => "Responses"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "HTTPCode_Backend_5XX", :unit => "Responses"}
  metric_group.save
  metric_group
end


def ensure_rds_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating RDS metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating RDS metric group"
    metric_group.frequency = @freq
    #metric_group.is_hidden = false
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "DiskQueueDepth"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "ReadLatency",     :unit => "ms"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "WriteLatency",     :unit => "ms"}
  metric_group.save
  metric_group
end


def ensure_ec2_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating EC2 metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating EC2 metric group"
    metric_group.frequency = @freq
    #metric_group.is_hidden = false
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge",   :name => "Running",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "Stopped",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "Pending",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "Shutting_down",  :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "Terminated",     :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "Stopping",       :unit => "Instances"}
  metric_group.save
  metric_group
end


def ensure_billing_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating AWS Billing metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating AWS Billing metric group"
    metric_group.frequency = @freq
    #metric_group.is_hidden = false
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "Total",        :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "EC2",          :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "RDS",          :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "S3",           :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "Route53",      :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "SimpleDB",     :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "SNS",          :unit => "USD"}
  metric_group.metrics << {:type => "ce_gauge_f",   :name => "DataTransfer", :unit => "USD"}
  metric_group.save
  metric_group
end

def create_aws_dashboard(service, metric_group, identifiers)
  log "Creating new AWS Dashboard for service #{service}"
  log "  with metrics #{metric_group.metrics}" if @debug

  dashboard = @config[service]["dashboard"] || "AWS #{service}"
  CopperEgg::CustomDashboard.create(metric_group, :name => dashboard, :identifiers => identifiers, :metrics => metric_group.metrics)
end


####################################################################

def ensure_metric_group(metric_group, service)
  if service == "elb"
    return ensure_elb_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "rds"
    return ensure_rds_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "ec2"
    return ensure_ec2_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "billing"
    return ensure_billing_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    log "Service #{service} not recognized"
  end
end

####################################################################


# metric group check
log "Checking for existence of AWS metric groups"

dashboards = CopperEgg::CustomDashboard.find
metric_groups = CopperEgg::MetricGroup.find

@services.each do |service|
  goodone = 0
  if @config[service] && @config[service]["group_name"] && @config[service]["group_label"]

    identifiers = nil
    if service == "elb"
      @elb = true
    elsif service == "rds"
      @rds = true
    elsif service == "ec2"
      @ec2 = true
      identifiers = ['ec2_instances']
    elsif service == "billing"
      @billing = true
      identifiers = ['aws_charges']
    else
      log "Unknown service #{service}.  Skipping"
      next
    end

    # create/update metric group
    metric_group = metric_groups.detect {|m| m.name == @config[service]["group_name"]}
    metric_group = ensure_metric_group(metric_group, service)

    # create dashboard
    dashboard = dashboards.detect {|d| d.name == @config[service]["dashboard"]} || create_aws_dashboard(service, metric_group, identifiers)

  end
end

monitor_aws()



