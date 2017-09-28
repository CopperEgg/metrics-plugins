#!/usr/bin/env ruby
#
# Copyright 2016 IDERA.  All rights reserved.
#

@base_path = '/usr/local/copperegg/ucm-metrics/remote_server/'
ENV['BUNDLE_GEMFILE'] = "#{@base_path}/Gemfile"

##################################################

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'net/ssh'
require 'benchmark'

class CopperEggAgentError < Exception; end

####################################################################

TIME_STRING = '%Y/%m/%d %H:%M:%S'
COLLECTL_REQUIRED_HEADERS = %w(#cpu Free Buff Cach KBRead KBWrit KBIn KBOut)
COLLECTL_HEADERS_UCM = %w(cpu_total free_memory buff_memory cach_memory disk_read_kb disk_write_kb
network_in_kb network_out_kb)
UNITS_FACTOR = {
  'B'  => 1024**0,
  'K' => 1024**1,
  'M' => 1024**2,
  'G' => 1024**3,
  'T' => 1024**4
}

MAX_RETRIES = 30
last_failure = 0

MAX_SETUP_RETRIES = 5
setup_retries = MAX_SETUP_RETRIES

opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

config_file = "#{@base_path}config.yml"
@apihost = nil
@debug = false
@freq = 60
@interupted = false
@worker_pids = []
@services = []

def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60 (for 60s updates. Valid values: 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712 (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com (API endpoint to use [DEBUG ONLY])'
end

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
  log(str) if @debug == true
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

def convert_to_bytes(size, unit)
  size.to_f * UNITS_FACTOR[unit]
end

def process_single_collectl_metric(collectl_headers_and_metrics, header)
  headers = collectl_headers_and_metrics[0]
  values  = collectl_headers_and_metrics[1]
  index   = headers.find_index(header)
  return nil if index.nil?

  return values[index]
end


def get_collectl_metrics(session, command, collectl_headers_and_metrics)
  read_data = false

  session.open_channel do |channel|
    channel.on_data do |ch, data|
      data.split("\n").each do |line|
        # don't start reading till we get headers
        read_data = true if line.include?('#cpu ')
        next if read_data == false

        collectl_headers_and_metrics.push line.split(' ')
      end
    end
    channel.exec command
  end
end

def get_system_load(session, command, metrics)
  session.open_channel do |channel|
    channel.on_data do |ch, data|
      load_numbers = data.split(' ')[0..2]
      metrics['load_1_min'] = load_numbers[0]
      metrics['load_5_min'] = load_numbers[1]
      metrics['load_15_min'] = load_numbers[2]
    end
    channel.exec command
  end
end

def get_filesystem_info(session, command, metrics)
  session.open_channel do |channel|
    channel.on_data do |ch, data|
      data.split(' ').each do |root_partition|
        metrics['root_filled'] = root_partition.split('%').first if root_partition.include?('%')
      end
    end
    channel.exec command
  end
end

def get_general_uptime(session, command, metrics)
  session.open_channel do |channel|
    start_time = end_time = 0
    channel.on_data do |ch, data|
      end_time = Time.now.to_f
      metrics['ping'] = (end_time - start_time).round(3) * 1000
    end
    start_time = Time.now.to_f
    channel.exec command
  end
end

def monitor_single_remote(remote_server, group_name)
  return if @interrupted

  host        = remote_server['host']
  user        = remote_server['user']
  password    = remote_server['password']
  port        = remote_server['port']
  key         = @base_path + remote_server['key']
  object_name = remote_server['name']

  password = nil if password.empty?

  log  "Monitoring remote server: #{object_name}"

  while !@interupted do
    return if @interrupted

    benchmark_result = Benchmark.measure do
      metrics = {}
      collectl_headers_and_metrics = []
      begin
        Net::SSH.start(host, user, password: password, port: port, paranoid: false, keys: key,
          timeout: 5)  do |session|
          get_collectl_metrics(session, 'collectl -scmnd --count 1', collectl_headers_and_metrics)
          get_system_load(session, 'cat /proc/loadavg', metrics)
          get_filesystem_info(session, 'df -lh | grep -wF /', metrics)
          get_general_uptime(session, 'date', metrics)

          session.loop
        end

        COLLECTL_REQUIRED_HEADERS.each_with_index do |header, index|
          processed_metric = process_single_collectl_metric(collectl_headers_and_metrics, header)
          metrics[COLLECTL_HEADERS_UCM[index]] = processed_metric unless processed_metric.nil?
        end

        metrics['free_memory'] = convert_to_bytes(metrics['free_memory'], metrics['free_memory'][-1])
        metrics['buff_memory'] = convert_to_bytes(metrics['buff_memory'], metrics['buff_memory'][-1])
        metrics['cach_memory'] = convert_to_bytes(metrics['cach_memory'], metrics['cach_memory'][-1])

        logd 'Sending sample to API'
        logd "#{group_name} - #{object_name} - #{Time.now} - #{metrics.inspect}"

        CopperEgg::MetricSample.save(group_name, object_name, Time.now.to_i, metrics)
      rescue SocketError => so_e
        log "SocketError  #{so_e}"
      rescue StandardError => st_e
        log "StandardError  #{st_e}. #{st_e.backtrace.join("\n")}"
      end
    end

    interruptible_sleep((@freq - benchmark_result.real).to_i)
  end
end

def monitor_remote_server(remote_servers, group_name)
  remote_servers.each do |remote_server|
    child_pid = fork {
      trap('INT') { child_interrupt unless @interrupted }
      trap('TERM') { child_interrupt unless @interrupted }
      last_failure = 0
      retries = MAX_RETRIES
      begin
        monitor_single_remote(remote_server, group_name)
      rescue => e
        log "Error monitoring #{remote_server['name']}.  Retrying (#{retries}) more times..."
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

def ensure_remote_server_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating Remote Server metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label, frequency: @freq)
  else
    log 'Updating Remote Server metric group'
    metric_group.frequency = @freq
  end

  metric_group.metrics = []

  metric_group.metrics << { type: 'ce_gauge_f', name: 'load_1_min',     label: 'Load Avg (1 min)', unit: '' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'load_5_min',     label: 'Load Avg (5 min)', unit: '' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'load_15_min',    label: 'Load Avg (15 min)', unit: '' }

  metric_group.metrics << { type: 'ce_gauge_f', name: 'ping',           label: 'SSH ping', unit: 'ms' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'root_filled',    label: 'Root partition filled (%)', unit: '%' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'cpu_total',      label: 'CPU consumption (%)', unit: '%' }

  metric_group.metrics << { type: 'ce_gauge',   name: 'free_memory',    label: 'Free Memory', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge',   name: 'buff_memory',    label: 'Buffered Memory', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge',   name: 'cach_memory',    label: 'Cached Memory', unit: 'b' }

  metric_group.metrics << { type: 'ce_gauge_f', name: 'disk_read_kb',   label: 'Disk read', unit: 'kb' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'disk_write_kb',  label: 'Disk write', unit: 'kb' }

  metric_group.metrics << { type: 'ce_gauge_f', name: 'network_in_kb',  label: 'Network in', unit: 'kb' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'network_out_kb', label: 'Network out', unit: 'kb' }

  metric_group.save
  metric_group
end

def create_remote_server_dashboard(metric_group, name, server_list)
  log 'Creating new Remote Server Dashboard'
  metrics = metric_group.metrics.map { |metric| metric['name'] }
  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics,
                                    service: 'remote_server')
end

def ensure_metric_group(metric_group, service)
  if service == 'remote_server'
    return ensure_remote_server_metric_group(metric_group, @config[service]['group_name'],
      @config[service]['group_label'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'remote_server'
    create_remote_server_dashboard(metric_group, @config[service]['dashboard'],
      @config[service]['servers'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'remote_server'
    monitor_remote_server(@config[service]['servers'], metric_group.name)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

######### MAIN SCRIPT #########

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
    CopperEgg::Api.apikey = @config['copperegg']['apikey'] unless @config['copperegg']['apikey'].nil?
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

@freq = 60 unless [60, 300, 900, 3600, 216_00].include?(@freq)

log "Update frequency set to #{@freq}s."


trap('INT') { parent_interrupt }
trap('TERM') { parent_interrupt }


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
      dashboard = dashboards.nil? ? nil : dashboards.detect { |d| d.name == @config[service]['dashboard'] } ||
          create_dashboard(service, metric_group)
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
