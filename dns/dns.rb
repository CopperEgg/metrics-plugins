#!/usr/bin/env ruby
#
# Copyright 2016 IDERA.  All rights reserved.
#

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'dnsruby'
require 'benchmark'

include Dnsruby

class CopperEggAgentError < Exception; end

####################################################################

def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712 (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com (API endpoint to use [DEBUG ONLY])'
end

TIME_STRING = '%Y/%m/%d %H:%M:%S'

def log(string)
  begin
    puts "#{Time.now.strftime(TIME_STRING)} pid:#{Process.pid}> #{string}"
    $stdout.flush
  rescue StandardError
    # do nothing -- just catches unimportant errors when we kill the process
    # and it's in the middle of logging or flushing.
  end
end

def logd(str)
  log(str) if @debug
end

def interruptible_sleep(seconds)
  seconds.times { sleep 1 unless @interrupted }
end

def child_interrupt
  @interrupted = true
  log "Exiting pid #{Process.pid}"
end

def parent_interrupt
  log 'INTERRUPTED'
  @interrupted = true

  @worker_pids.each do |pid|
    Process.kill 'TERM', pid
    log "Killed pid #{pid}"
  end

  log 'Waiting for all workers to exit'
  Process.waitall

  if @monitor_thread
    log 'Waiting for monitor thread to exit'
    @monitor_thread.join
  end

  log 'Exiting cleanly'
  exit
end

####################################################################

opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

base_path = '/usr/local/copperegg/ucm-metrics/dns'
config_file = "#{base_path}/config.yml"
@apihost = nil
@debug = false
@freq = 60
@interupted = false
@worker_pids = []
@services = []

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
    when '--frequency'
      @freq = arg.to_i
    when '--apihost'
      CopperEgg::Api.host = arg
  end
end

@config = YAML.load(File.open(config_file))

unless @config.nil?
  unless @config['copperegg'].nil?
    CopperEgg::Api.apikey = @config['copperegg']['apikey'] unless @config['copperegg']['apikey'].nil? && CopperEgg::Api.apikey.nil?
    CopperEgg::Api.host = @config['copperegg']['apihost'] unless @config['copperegg']['apihost'].nil?
    @freq = @config['copperegg']['frequency'] unless @config['copperegg']['frequency'].nil?
    @services = @config['copperegg']['services']
  else
    log 'You have no copperegg entry in your config.yml!'
    log 'Edit your config.yml and restart.'
    exit
  end
end

if CopperEgg::Api.apikey.nil?
  log 'You need to supply an apikey with the -k option or in the config.yml.'
  exit
end

if @services.empty?
  log 'No services listed in the config file.'
  log 'Nothing will be monitored!'
  exit
end

@freq = 60 unless [15, 60, 300, 900, 3600, 216_00].include?(@freq)

log "Update frequency set to #{@freq}s."

####################################################################

def monitor_single_dns(dns_server, group_name)
  return if @interrupted

  object_name  = dns_server['name']
  query        = dns_server['query']
  type         = dns_server['type']
  timeout      = dns_server['timeout'].to_i
  match        = dns_server['match']
  name_servers = dns_server['nameservers']

  timeout = 5 if timeout.nil?
  match = nil if !match.nil? and match.strip == ""

  log  "Monitoring DNS: #{object_name}"

  log "query      : '#{query}'"
  log "type       : '#{type}'"
  log "timeout    : '#{timeout}'"
  log "match      : '#{match}'"
  log "nameservers: '#{name_servers}'"

  if name_servers.nil?
    resolver = Resolver.new
  else
    resolver = Resolver.new({ nameserver: name_servers })
  end
  resolver.do_caching = false
  resolver.query_timeout = timeout

  while !@interupted do
    return if @interrupted

    response_metric = 0
    match_metric = 0

    benchmark_result = Benchmark.measure do
      begin
        response = resolver.query(query, type)
        if response.answer.nil?
          logd "Probably the type of entry [A, CNAME, MX] you supplied for query [#{object_name}] is incorrect"
        else
          response_metric = 1
          if !match.nil? && response.answer.first.rdata.to_s.include?(match)
            logd "matches for #{object_name}"
            match_metric = 1
          else
            logd "not matches for #{object_name}"
          end
        end
      rescue Dnsruby::NXDomain => nxdomain
        logd "The domain [#{object_name}] doesn't exist !"
      rescue Dnsruby::ResolvTimeout => resolv_timeout
        logd "Timeout while querying for [#{object_name}]"
      rescue Dnsruby::OtherResolvError => other_resolv_error
        logd "OtherResolvError while querying for [#{object_name}]. This might be related to internet connectivity"
      rescue Dnsruby::Refused => refused
        logd "Server refused while querying for [#{object_name}]. Probably name servers are incorrect"
      rescue StandardError => se
        logd "Error #{se.inspect} while querying data for [#{object_name}]"
        logd se.backtrace[0..30].join("\n")
      end
    end

    metrics = {}
    metrics['response']       = response_metric
    metrics['response_time']  = benchmark_result.real * 1000
    metrics['match']          = match_metric unless match.nil?

    log "Sending sample to API "
    log "#{group_name} - #{object_name} - #{Time.now.to_i} - #{metrics.inspect}"

    CopperEgg::MetricSample.save(group_name, object_name, Time.now.to_i, metrics)
    interruptible_sleep((@freq - benchmark_result.real).to_i)
  end
end

def monitor_dns(dns_servers, group_name)
  dns_servers.each do |dns_server|
    child_pid = fork {
      trap('INT') { child_interrupt unless @interrupted }
      trap('TERM') { child_interrupt unless @interrupted }
      last_failure = 0
      retries = MAX_RETRIES
      begin
        monitor_single_dns(dns_server, group_name)
      rescue => e
        puts "Error monitoring #{dns_server['name']}.  Retrying (#{retries}) more times..."
        log "#{e.inspect}"
        logd e.backtrace[0..30].join("\n")
        raise e if @debug
        sleep 2
        retries -= 1
        retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
        last_failure = Time.now.to_i
        retry if retries > 0
        raise e
      end
    }
    @worker_pids.push child_pid
  end
end

def ensure_dns_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating DNS metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label, frequency: @freq)
  else
    log 'Updating DNS metric group'
    metric_group.frequency = @freq
  end

  metric_group.metrics = []

  metric_group.metrics << { type: 'ce_gauge',   name: 'response',      label: 'Response', unit: '' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'response_time', label: 'Response time',  unit: 'ms' }
  metric_group.metrics << { type: 'ce_gauge',   name: 'match',         label: 'Response match',   unit: '' }

  metric_group.save
  metric_group
end

def create_couchdb_dashboard(metric_group, name, server_list)
  log 'Creating new DNS Dashboard'
  metrics = metric_group.metrics.map { |metric| metric['name'] }
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
end

def ensure_metric_group(metric_group, service)
  if service == 'dns'
    return ensure_dns_metric_group(metric_group, @config[service]['group_name'], @config[service]['group_label'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'dns'
    create_couchdb_dashboard(metric_group, @config[service]['dashboard'], @config[service]['servers'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'dns'
    monitor_dns(@config[service]['servers'], metric_group.name)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

######### MAIN SCRIPT #########

trap('INT') { parent_interrupt }
trap('TERM') { parent_interrupt }

MAX_RETRIES = 30
last_failure = 0

MAX_SETUP_RETRIES = 5
setup_retries = MAX_SETUP_RETRIES

begin
  dashboards = CopperEgg::CustomDashboard.find
  metric_groups = CopperEgg::MetricGroup.find
rescue => e
  log "Error connecting to server.  Retrying (#{retries}) more times..."
  raise e if @debug

  sleep 2
  setup_retries -= 1
  retry if setup_retries > 0
  # If we can't succeed with setup on the servcies, let's just error out
  raise e
end

@services.each do |service|
  if @config[service] && !@config[service]['servers'].empty?
    begin
      log "Checking for existence of metric group for #{service}"
      metric_group = metric_groups.nil? ? nil : metric_groups.detect {|m| m.name == @config[service]['group_name']}
      metric_group = ensure_metric_group(metric_group, service)
      raise "Could not create a metric group for #{service}" if metric_group.nil?

      log "Checking for existence of #{service} Dashboard"
      dashboard = dashboards.nil? ? nil : dashboards.detect { |d| d.name == @config[service]['dashboard'] } || create_dashboard(service, metric_group)
      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log "Message : #{e.message.inspect}"
      logd "\nTrace :"
      logd e.backtrace[0..30].join("\n")
      next
    end
    monitor_service(service, metric_group)
  end
end

p Process.waitall
