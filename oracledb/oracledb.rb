#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'oci8'

class CopperEggAgentError < Exception; end

def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60                 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])'
end

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

def interruptible_sleep(seconds)
  seconds.times {|i| sleep 1 if !@interrupted}
end

def child_interrupt
  # child clean-up
  @interrupted = true
  log "Exiting pid #{Process.pid}"
end

def parent_interrupt
  log 'INTERRUPTED'
  # parent clean-up
  @interrupted = true

  @worker_pids.each do |pid|
    Process.kill 'TERM', pid
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

def connect_to_oracle(url, port, user, password)
  begin
    @cxn = OCI8.new(user, password, "#{url}:#{port}")
  rescue Exception => e
    log "Error connecting to oracle DB server for user #{user}, on #{url}:#{port}"
    return nil
  end
  return @cxn
end


def get_stats(cxn)
  stats = {}
  cxn.exec("SELECT name, value FROM V$SYSSTAT WHERE name IN ('db block gets from cache', 'consistent gets from cache',
  'physical reads cache', 'sorts (memory)', 'sorts (disk)', 'parse count (total)', 'execute count', 'consistent gets',
  'db block gets', 'physical reads', 'physical writes')") do |name,value|
    stats[name] = value.to_f
  end

  cxn.exec("SELECT namespace, gethitratio from V$LIBRARYCACHE where namespace = 'SQL AREA'") do |namespace, gethitratio|
    stats[namespace] = gethitratio.to_f
  end

  cxn.exec('select BUFFER_BUSY_WAIT, FREE_BUFFER_WAIT, WRITE_COMPLETE_WAIT from v$buffer_pool_statistics') do
  |buffer_busy_wait, free_buffer_wait, write_complete_wait|
    stats['buffer busy wait'] = buffer_busy_wait.to_f
    stats['free buffer wait'] = free_buffer_wait.to_f
    stats['write complete wait'] = write_complete_wait.to_f
  end

  cxn.exec('select SESSIONS_MAX, SESSIONS_CURRENT,SESSIONS_HIGHWATER,USERS_MAX from v$license') do
  |sessions_max, sessions_current, sessions_highest, users_max|
    stats['max concurrent sessions'] = sessions_max.to_i
    stats['current concurrent sessions'] = sessions_current.to_i
    stats['highest concurrent sessions'] = sessions_highest.to_i
    stats['max named users'] = users_max.to_i
  end
  return stats
end


def monitor_oracle_db(servers, group_name)
  log 'Monitoring oracle DB: '
  return if @interrupted

  until @interupted do
    return if @interrupted

    servers.each do |host|
      return if @interrupted
      start_time = Time.now
      cxn = connect_to_oracle(host['url'], host['port'].to_i, host['user'], host['password'])
      connect_time = Time.now - start_time

      if cxn.nil?
        log '[skipping]'
        next
      end

      begin
        curr_stats = get_stats(cxn)
        cxn.logoff
      rescue StandardError
        log "Error getting stats from: #{host['url']}, #{host['port']}, #{host['user']} [skipping]"
        next
      end

      metrics = {}
      # Buffer, Execution and I/O metrics
      metrics['buf_cache_hit'] = ((1 - (curr_stats['physical reads cache'] /
          (curr_stats['consistent gets from cache'] + curr_stats['db block gets from cache']))) * 100).round(2)
      metrics['mem_sort_ratio'] = ((100 * curr_stats['sorts (memory)']) /
          (curr_stats['sorts (disk)'] + curr_stats['sorts (memory)'])).round(2)
      metrics['parse_execute_ratio'] =  ((curr_stats['parse count (total)'] /
          curr_stats['execute count']) * 100).round(2)
      metrics['sql_area_ratio']= (100 * curr_stats['SQL AREA']).round(2)
      metrics['buf_busy_waits']= curr_stats['buffer busy wait']
      metrics['free_buf_waits']= curr_stats['free buffer wait']
      metrics['wrt_complete_waits']= curr_stats['write complete wait']
      metrics['consistent_gets']= curr_stats['consistent gets']
      metrics['db_block_gets']= curr_stats['db block gets']
      metrics['physical_reads']= curr_stats['physical reads']
      # Connection and User Count
      metrics['max_concurrent_sessions']= curr_stats['max concurrent sessions']
      metrics['curr_concurrent_sessions']= curr_stats['current concurrent sessions']
      metrics['highest_concurrent_sessions']= curr_stats['highest concurrent sessions']
      metrics['max_named_users']= curr_stats['max named users']
      # Connection Time
      metrics['connection_time'] = connect_time

      log "#{group_name} - #{host['name']} - #{Time.now.to_i} \n #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, host['name'], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end


def ensure_oracle_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating oracle DB metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label, frequency: @freq)
  else
    log 'Updating oracle DB metric group'
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  # Buffer, Execution and I/O metrics
  metric_group.metrics << {type: 'ce_gauge_f', name: 'buf_cache_hit', position: 0,
                           label: 'Buffer Cache Hit Ratio', unit: '%'}
  metric_group.metrics << {type: 'ce_gauge_f', name: 'mem_sort_ratio', position: 1,
                           label: 'In Memory Sort Ratio', unit: '%'}
  metric_group.metrics << {type: 'ce_gauge_f', name: 'parse_execute_ratio', position: 2,
                           label: 'Parse to Execute Ratio', unit: '%'}
  metric_group.metrics << {type: 'ce_gauge_f', name: 'sql_area_ratio', position: 3,
                           label: 'SQL Area Get Ratio', unit: '%'}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_busy_waits', position: 4, label: 'Buffer Busy Wait'}
  metric_group.metrics << {type: 'ce_counter', name: 'free_buf_waits', position: 5, label: 'Free Buffer Waits'}
  metric_group.metrics << {type: 'ce_counter', name: 'wrt_complete_waits', position: 6, label: 'Write Complete Wait'}
  metric_group.metrics << {type: 'ce_counter', name: 'consistent_gets', position: 7, label: 'Consistent Gets'}
  metric_group.metrics << {type: 'ce_counter', name: 'db_block_gets', position: 8, label: 'DB Block Gets'}
  metric_group.metrics << {type: 'ce_counter', name: 'physical_reads', position: 9, label: 'Physical Reads'}
  # Connection and User Count
  metric_group.metrics << {type: 'ce_counter', name: 'max_concurrent_sessions', position: 10,
                           label: 'Maximum Concurrent User Sessions Allowed', unit: 'sessions'}
  metric_group.metrics << {type: 'ce_counter', name: 'curr_concurrent_sessions', position: 11,
                           label: 'Current Concurrent User Sessions', unit: 'sessions'}
  metric_group.metrics << {type: 'ce_counter', name: 'highest_concurrent_sessions', position: 12,
                           label: 'Highest Concurrent User Sessions', unit: 'sessions'}
  metric_group.metrics << {type: 'ce_counter', name: 'max_named_users', position: 13,
                           label: 'Maximum Named Users Allowed'}
  # Connection Time
  metric_group.metrics << {type: 'ce_gauge_f', name: 'connection_time', position: 14,
                           label: 'Connection Time', unit: 'seconds'}
  metric_group.save
  return metric_group
end

def create_oracle_dashboard(metric_group, name)
  log 'Creating new Oracle DB Dashboard'
  metrics = metric_group.metrics || []
  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics)
end

####################################################################

TIME_STRING='%Y/%m/%d %H:%M:%S'

# get options
opts = GetoptLong.new(
    ['--help',      '-h', GetoptLong::NO_ARGUMENT],
    ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
    ['--verbose',   '-v', GetoptLong::NO_ARGUMENT],
    ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
    ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
    ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
    ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

base_path = '/usr/local/copperegg/ucm-metrics/oracledb'
config_file = "#{base_path}/config.yml"

@apihost = nil
@debug = false
@verbose = false
@freq = 60
@interupted = false
@worker_pids = []
@services = []

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
    when '--frequency'
      @freq = arg.to_i
    when '--apihost'
      CopperEgg::Api.host = arg
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

unless @config.nil?
  # load config
  unless @config['copperegg'].nil?
    CopperEgg::Api.apikey = @config['copperegg']['apikey'] unless @config['copperegg']['apikey'].nil?
    CopperEgg::Api.host = @config['copperegg']['host'] unless @config['copperegg']['host'].nil?
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

@freq = 60 unless [5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."

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
  log "Error connecting to server.  Retrying (#{setup_retries}) more times..."
  raise e if @debug
  sleep 2
  setup_retries -= 1
  retry if setup_retries > 0
  # If we can't succeed with setup on the services, let's just error out
  raise e
end


@services.each do |service|
  raise CopperEggAgentError.new("Service #{service} not recognized") unless service == 'oracledb'

  if @config[service] && !@config[service]['servers'].empty?
    begin
      log "Checking for existence of metric group for #{service}"

      metric_group = metric_groups.detect { |m| m.name == @config[service]['group_name'] } unless metric_groups.nil?
      if metric_group.nil?
        metric_group = ensure_oracle_metric_group(metric_group, @config[service]['group_name'],
                                                  @config[service]['group_label'])
      end

      raise "Could not create a metric group for #{service}" if metric_group.nil?
      log "Checking for existence of #{@config[service]['dashboard']}"

      dashboard = dashboards.detect { |d| d.name == @config[service]['dashboard'] } unless dashboards.nil?
      dashboard = create_oracle_dashboard(metric_group, @config[service]['dashboard']) if dashboard.nil?

      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log 'Error while creating Metric group/dashboard'
      log e.message
      log e.inspect if @debug
      log e.backtrace[0..30].join("\n") if @debug
      next
    end

    child_pid = fork {
      trap('INT') { child_interrupt unless @interrupted }
      trap('TERM') { child_interrupt unless @interrupted }
      last_failure = 0
      retries = MAX_RETRIES
      begin
        monitor_oracle_db(@config[service]['servers'], metric_group.name)
      rescue => e
        log "Error monitoring #{service}.  Retrying (#{retries}) more times..."
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        raise e   if @debug
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

p Process.waitall



