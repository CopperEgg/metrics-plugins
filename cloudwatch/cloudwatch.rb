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
require 'time'

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
  while !@interrupted && (Time.now.to_i < end_time)
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
  ['--verbose',   '-v', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

config_file = "config.yml"
apikey = nil
@apihost = nil
@debug = false
@verbose = false
@freq = 60  # update frequency in seconds
@interupted = false
@supported_services = [ 'ec2', 'elb', 'rds', 'billing' ]
@worker_pids = []

# Options and examples:
opts.each do |opt, arg|
  case opt
  when '--help'
    help
    exit
  when '--debug'
    @debug = true
  when '--verbose'
    @verbose = true
  when '--config'
    config_file = arg
  when '--apikey'
    CopperEgg::Api.apikey = arg
  when '--apihost'
    CopperEgg::Api.host = arg
  when '--frequency'
    @freq = arg.to_i
  end
end

@verbose = true if @debug

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    CopperEgg::Api.apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && apikey.nil?
    @freq = @config["copperegg"]["frequency"] if !@config["copperegg"]["frequency"].nil?
  else
    log "You have no copperegg entry in your config.yml!"
    log "Edit your config.yml and restart."
    exit
  end
  if !@config["aws"].nil?
    @services = @config['aws']['services']
    log "Reading config: services are #{@services.inspect}\n"

    @regions = @config['aws']['regions']
    @regions = ['us-east-1'] if !@regions || @regions.length == 0
    log "Reading config: regions are #{@regions.inspect}\n"
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

@freq = 60 if ![5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."

@aws_config_default = { :access_key_id => @config["aws"]["access_key_id"],
                       :secret_access_key => @config["aws"]["secret_access_key"],
                       :max_retries => 2,
                       :http_open_timeout => 5,
                       :http_read_timeout => 10 }

####################################################################
def child_interrupt
  # do child clean-up here
  @interrupted = true
  log "Exiting pid #{Process.pid}"
end

def parent_interrupt
  log "INTERRUPTED"
  # parent clean-up
  @interrupted = true

  @worker_pids.each do |pid|
    Process.kill 'TERM', pid
  end

  sleep 1

  @worker_pids.each do |pid|
    Process.kill 'KILL', pid
  end

  log "Waiting for all workers to exit"
  Process.waitall

  if @monitor_thread
    log "Waiting for monitor thread to exit"
    @monitor_thread.join
  end

  log "Exiting cleanly"
  exit
end

####################################################################
def fetch_cloudwatch_stats(namespace, metric_name, stats, dimensions, cl=nil, freq=@freq)

  # need to create it fresh every time because we can switch regions arbitrarily
  start_time = (Time.now - freq).iso8601

  begin
    cl ||= AWS::CloudWatch::Client.new()
    stats_hash = { :namespace => namespace,
                   :metric_name => metric_name,
                   :dimensions => dimensions,
                   :start_time => start_time,
                   :end_time => Time.now.utc.iso8601,
                   :period => freq,
                   :statistics => stats }
    stats = cl.get_metric_statistics(stats_hash)
    log "fetch_cl_st:  cl               : #{cl.inspect}" if @debug
    log "fetch_cl_st:  stats_hash (post):    #{stats_hash.inspect}" if @debug
    log "fetch_cl_st:  stats     (reply):    #{stats.inspect}" if @debug
    #log "fetch_cl_st:  cl:  #{cl.inspect}" if @debug

  rescue Exception => e
    log "Error getting cloudwatch stats: #{metric_name} [skipping]"
    log "Stats hash: #{stats_hash.inspect}" if @debug
    log e.inspect if @debug
    log e.backtrace.join("\n") if @debug
    stats = nil
  end
  return stats
end


def monitor_aws_ec2(group_name)
  log "Monitoring AWS EC2.."

  while !@interrupted do
    return if @interrupted
    total_ec2_counts = {}
    total_ec2_counts['running'] = 0
    total_ec2_counts['stopped'] = 0
    total_ec2_counts['pending'] = 0
    total_ec2_counts['shutting_down'] = 0
    total_ec2_counts['terminated'] = 0
    total_ec2_counts['stopping'] = 0
    post_total = true

    @regions.each do |region|
      region_ec2_counts = {}
      region_ec2_counts['running'] = 0
      region_ec2_counts['stopped'] = 0
      region_ec2_counts['pending'] = 0
      region_ec2_counts['shutting_down'] = 0
      region_ec2_counts['terminated'] = 0
      region_ec2_counts['stopping'] = 0

      begin
        AWS.config(@aws_config_default.merge({
          :ec2_endpoint => "ec2.#{region}.amazonaws.com",
          :cloud_watch_endpoint => "monitoring.#{region}.amazonaws.com"
        }))
        ec2 = AWS::EC2.new()

        instances = ec2.instances
        instances.each do |instance|
          status = instance.status.to_s
          region_ec2_counts[instance.status.to_s.downcase] += 1
          total_ec2_counts[instance.status.to_s.downcase] += 1
        end

        log "ec2: #{group_name} - #{region} - #{region_ec2_counts.inspect}" if @verbose
        CopperEgg::MetricSample.save(group_name, region, Time.now.to_i, region_ec2_counts)
      rescue Exception => e
        log "Exception getting ec2 instances for region #{region}: #{e.to_s}.\nIgnoring and moving on."
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
        post_total = false  # don't post a possibly incorrect total
      end

    end

    begin
      log "ec2: #{group_name} - total - #{total_ec2_counts.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, "total", Time.now.to_i, total_ec2_counts) if post_total
    rescue Exception => e
      log "Exception posting ec2 instance data: #{e.to_s}.\nIgnoring and moving on."
      log e.inspect if @debug
      log e.backtrace.join("\n") if @debug
    end

    sleep_until @freq
  end
end

def monitor_aws_elb(group_name)
  log "Monitoring AWS ELB.."

  while !@interupted do
    return if @interrupted

    @regions.each do |region|
      begin
        AWS.config(@aws_config_default.merge({
          :elb_endpoint => "elasticloadbalancing.#{region}.amazonaws.com",
          :ec2_endpoint => "ec2.#{region}.amazonaws.com",
          :cloud_watch_endpoint => "monitoring.#{region}.amazonaws.com"
        }))
        elb = AWS::ELB.new()
        cl = AWS::CloudWatch::Client.new()

        lbs = elb.load_balancers()
        lbs.each do |lb|
          metrics = {}
          instance = lb.name

          stats = fetch_cloudwatch_stats("AWS/ELB", "Latency", ['Average'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "elb stat: #{lb.name} : Latency : #{stats[:datapoints][0][:average]*1000} ms" if @debug
            metrics["Latency"] = stats[:datapoints][0][:average]*1000
          else
            metrics["Latency"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/ELB", "RequestCount", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "elb stat: #{lb.name} : RequestCount : #{stats[:datapoints][0][:sum].to_i} requests" if @debug
            metrics["RequestCount"] = stats[:datapoints][0][:sum].to_i
          else
            metrics["RequestCount"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_2XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "elb stat: #{lb.name} : HTTPCode_Backend_2XX : #{stats[:datapoints][0][:sum].to_i} Successes" if @debug
            metrics["HTTPCode_Backend_2XX"] = stats[:datapoints][0][:sum].to_i
          else
            metrics["HTTPCode_Backend_2XX"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_Backend_5XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "elb stat: #{lb.name} : HTTPCode_Backend_5XX : #{stats[:datapoints][0][:sum].to_i} Errors" if @debug
            metrics["HTTPCode_Backend_5XX"] = stats[:datapoints][0][:sum].to_i
          else
            metrics["HTTPCode_Backend_5XX"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/ELB", "HTTPCode_ELB_5XX", ['Sum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "elb stat: #{lb.name} : HTTPCode_ELB_5XX : #{stats[:datapoints][0][:sum].to_i} Errors" if @debug
            metrics["HTTPCode_ELB_5XX"] = stats[:datapoints][0][:sum].to_i
          else
            metrics["HTTPCode_ELB_5XX"] = 0
          end

          # FIXME: doesn't work right
          #stats = fetch_cloudwatch_stats("AWS/ELB", "HealthyHostCount", ['Maximum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          #if stats != nil && stats[:datapoints].length > 0
            #log "elb stat: #{lb.name} : HealthyHostCount : #{stats[:datapoints][0][:maximum].to_i} Errors" if @debug
            #metrics["HealthyHostCount"] = stats[:datapoints][0][:maximum].to_i
          #else
            #metrics["HealthyHostCount"] = 0
          #end

          # FIXME: doesn't work right
          #stats = fetch_cloudwatch_stats("AWS/ELB", "UnHealthyHostCount", ['Maximum'], [{:name=>"LoadBalancerName", :value=>lb.name}], cl)
          #if stats != nil && stats[:datapoints].length > 0
            #log "elb stat: #{lb.name} : UnHealthyHostCount : #{stats[:datapoints][0][:maximum].to_i} Errors" if @debug
            #metrics["UnHealthyHostCount"] = stats[:datapoints][0][:maximum].to_i
          #else
            #metrics["UnHealthyHostCount"] = 0
          #end

          log "elb: #{group_name} - #{instance} - #{metrics.inspect}" if @verbose
          CopperEgg::MetricSample.save(group_name, instance, Time.now.to_i, metrics)
        end

      rescue Exception => e
        log "Exception getting elb list for region #{region}:\n#{e.to_s}.\nIgnoring and moving on"
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
      end
    end

    sleep_until @freq
  end
end

def monitor_aws_rds(group_name)
  log "Monitoring AWS RDS.."

  while !@interupted do
    return if @interrupted
    @regions.each do |region|
      begin
        AWS.config(@aws_config_default.merge({
          :rds_endpoint => "rds.#{region}.amazonaws.com",
          :ec2_endpoint => "ec2.#{region}.amazonaws.com",
          :cloud_watch_endpoint => "monitoring.#{region}.amazonaws.com"
        }))
        rds = AWS::RDS.new()
        cl = AWS::CloudWatch::Client.new()

        dbs = rds.db_instances()
        dbs.each do |db|
          return if @interrupted
          metrics = {}
          instance = db.db_instance_id

          stats = fetch_cloudwatch_stats("AWS/RDS", "DiskQueueDepth", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]} queue depth" if @debug
            metrics["DiskQueueDepth"] = stats[:datapoints][0][:average].to_i
          else
            metrics["DiskQueueDepth"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "ReadLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} read latency (ms)" if @debug
            metrics["ReadLatency"] = stats[:datapoints][0][:average]*1000
          else
            metrics["ReadLatency"] = 0
          end

          stats = fetch_cloudwatch_stats("AWS/RDS", "WriteLatency", ['Average'], [{:name=>"DBInstanceIdentifier", :value=>db.db_instance_id}], cl)
          if stats != nil && stats[:datapoints].length > 0
            log "RDS: #{db.db_instance_id} #{stats[:datapoints][0][:average]*1000} write latency (ms)" if @debug
            metrics["WriteLatency"] = stats[:datapoints][0][:average]*1000
          else
            metrics["WriteLatency"] = 0
          end

          log "rds: #{group_name} - #{instance} - #{metrics.inspect}" if @verbose
          CopperEgg::MetricSample.save(group_name, instance, Time.now.to_i, metrics)
        end

      rescue Exception => e
        log "Exception getting rds list for region #{region}:\n#{e.to_s}.\nIgnoring and moving on"
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
      end
    end

    sleep_until @freq
  end
end

def monitor_aws_billing(group_name)
  log "Monitoring AWS Billing.."
  AWS.config(@aws_config_default) # don't need to update it every loop

  while !@interrupted do
    return if @interrupted

    metrics = {}

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing Total: #{stats[:datapoints]}" if @debug
      metrics["Total"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["Total"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonEC2"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats.datapoints.length > 0
      log "Billing EC2: #{stats[:datapoints]}" if @debug
      metrics["EC2"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["EC2"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRDS"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing RDS: #{stats[:datapoints]}" if @debug
      metrics["RDS"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["RDS"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonS3"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing S3: #{stats[:datapoints]}" if @debug
      metrics["S3"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["S3"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonRoute53"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing Route53: #{stats[:datapoints]}" if @debug
      metrics["Route53"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["Route53"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"SimpleDB"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing SimpleDB: #{stats[:datapoints]}" if @debug
      metrics["SimpleDB"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["SimpleDB"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AmazonSNS"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing SNS: #{stats[:datapoints]}" if @debug
      metrics["SNS"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["SNS"] = 0.0
    end

    stats = fetch_cloudwatch_stats("AWS/Billing", "EstimatedCharges", ['Maximum'], [{:name=>"ServiceName", :value=>"AWSDataTransfer"},
                                                      {:name=>"Currency", :value=>"USD"}], nil, @freq*720)
    if stats != nil && stats[:datapoints].length > 0
      log "Billing Total: #{stats[:datapoints]}" if @debug
      metrics["DataTransfer"] = stats[:datapoints][0][:maximum].to_f
    else
      metrics["DataTransfer"] = 0.0
    end

    log "billing: #{group_name} - aws_charges - #{metrics.inspect}" if @verbose
    begin
      CopperEgg::MetricSample.save(group_name, "aws_charges", Time.now.to_i, metrics)
    rescue Exception => e
        log "Exception getting AWS Billing information: #{e.to_s}.\nIgnoring and moving on."
        log e.inspect if @debug
        log e.backtrace.join("\n") if @debug
    end

    sleep_until @freq
  end
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
  metric_group.metrics << {:type => "ce_gauge",   :name => "running",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "stopped",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "pending",        :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "shutting_down",  :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "terminated",     :unit => "Instances"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "stopping",       :unit => "Instances"}
  metric_group.save
  metric_group
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
  metric_group.metrics << {:type => "ce_gauge",   :name => "HTTPCode_ELB_5XX",     :unit => "Responses"}

  # FIXME: doesn't work right
  #metric_group.metrics << {:type => "ce_gauge",   :name => "HealthyHostCount",     :unit => "Hosts"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "UnHealthyHostCount",   :unit => "Hosts"}

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

def ensure_aws_dashboard(service, metric_group, identifiers)
  dashboards = CopperEgg::CustomDashboard.find
  dashboard_name = @config[service]["dashboard"] || "AWS #{service}"
  dashboard = nil
  dashboard = dashboards.detect {|d| d.name == dashboard_name} if dashboards
  if !dashboard.nil?
    log "Dashboard #{dashboard_name} exists.  Skipping create"
    return
  end

  log "Creating new AWS Dashboard '#{dashboard_name}' for service #{service}"
  log "  with metrics #{metric_group.metrics.inspect}" if @debug

  CopperEgg::CustomDashboard.create(metric_group, :name => dashboard_name, :identifiers => identifiers, :metrics => metric_group.metrics.reverse)
end


####################################################################

def monitor_aws(service)
  if service == "ec2"
    monitor_aws_ec2(@config[service]["group_name"])
  elsif service == "elb"
    monitor_aws_elb(@config[service]["group_name"])
  elsif service == "rds"
    monitor_aws_rds(@config[service]["group_name"])
  elsif service == "billing"
    monitor_aws_billing(@config[service]["group_name"])
  else
    log "Service #{service} not recognized"
  end
end

def ensure_metric_group(metric_group, service)
  if service == "ec2"
    return ensure_ec2_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "elb"
    return ensure_elb_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "rds"
    return ensure_rds_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "billing"
    return ensure_billing_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    log "Service #{service} not recognized"
  end
end

####################################################################


# metric group check
log "Checking for existence of AWS metric groups"


trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }

@services.each do |service|
  if @config[service] && @config[service]["group_name"] && @config[service]["group_label"]

    if !@supported_services.include?(service)
      log "Unknown service #{service}.  Skipping"
      next
    end

    identifiers = nil
    if service == "billing"
      identifiers = ['aws_charges']
    end

    # create/update metric group
    metric_groups = CopperEgg::MetricGroup.find
    metric_group = nil
    metric_group = metric_groups.detect {|m| m.name == @config[service]["group_name"]} if metric_groups
    metric_group = ensure_metric_group(metric_group, service)

    # create dashboard
    dashboard = ensure_aws_dashboard(service, metric_group, identifiers)

    child_pid = fork {
      trap("INT") { child_interrupt if !@interrupted }
      trap("TERM") { child_interrupt if !@interrupted }
      monitor_aws(service)
    }
    @worker_pids.push child_pid

    sleep 3  # Give aws api a little breathing space

  end
end

# ... wait for all processes to exit ...
p Process.waitall
