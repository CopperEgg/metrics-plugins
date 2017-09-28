#!/usr/bin/env ruby
#
# CopperEgg memcached monitoring  memcached.rb
#
# Copyright 2013 Chris Snell <chris.snell@revinate.com>
#
# License:: MIT License

base_path = '/usr/local/copperegg/ucm-metrics/memcached'
ENV['BUNDLE_GEMFILE'] = "#{base_path}/Gemfile"

##################################################

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'socket'

class CopperEggAgentError < Exception; end

####################################################################################################
def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60                 (for 60s updates. Valid values: 15, 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])'
end

def log(str)
  begin
    str.split("\n").each do |s|
      puts "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')} pid:#{Process.pid}> #{s}"
    end
    $stdout.flush
  rescue StandardError
    # do nothing -- just catches unimportant errors when we kill the process
  end
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

def connect_to_memcached(hostname, port)
  begin
    @cxn = TCPSocket.open(hostname, port)
  rescue StandardError => e
    log "Error connecting to memcached on #{hostname}:#{port}"
    log "Error string : #{e.message}" if @debug
    log e.backtrace[0..30].join("\n") if @debug
    return nil
  end
  return @cxn
end

def get_stats(mccxn)
  mccxn.send("stats\r\n", 0)

  statistics = []
  loop do
    data = mccxn.recv(4096)
    if !data || data.empty?
      break
    end
    statistics << data
    if statistics.join.split(/\n/)[-1] =~ /END/
      break
    end
  end

  stat_hash = {}

  statistics.join.split("\n").each do |line|
    if line =~ /^STAT (\w+) (\d+)/
      stat_hash[$1] = $2
    end
  end

  return stat_hash
end

def monitor_memcached(mc_servers, group_name)
  log 'Monitoring memcached: '

  until @interupted do
    return if @interrupted

    mc_servers.each do |mchost|
      return if @interrupted

      mccxn = connect_to_memcached(mchost['hostname'], mchost['port'].to_i)
      if mccxn.nil?
        log '[skipping]'
        next
      end
      begin
        curr_stats = get_stats(mccxn)
      rescue StandardError
        log "Error getting stats from: #{mchost['hostname']}, #{mchost['port']} [skipping]"
        next
      end

      metrics = {}
      metrics['uptime']                = curr_stats['uptime'].to_i
      metrics['rusage_user']           = curr_stats['rusage_user'].to_i
      metrics['rusage_system']         = curr_stats['rusage_system'].to_i
      metrics['curr_connections']      = curr_stats['curr_connections'].to_i
      metrics['total_connections']     = curr_stats['total_connections'].to_i
      metrics['connection_structures'] = curr_stats['connection_structures'].to_i
      metrics['reserved_fds']          = curr_stats['reserved_fds'].to_i
      metrics['cmd_get']               = curr_stats['cmd_get'].to_i
      metrics['cmd_set']               = curr_stats['cmd_set'].to_i
      metrics['cmd_flush']             = curr_stats['cmd_flush'].to_i
      metrics['cmd_touch']             = curr_stats['cmd_touch'].to_i
      metrics['get_hits']              = curr_stats['get_hits'].to_i
      metrics['get_misses']            = curr_stats['get_misses'].to_i
      metrics['delete_misses']         = curr_stats['delete_misses'].to_i
      metrics['delete_hits']           = curr_stats['delete_hits'].to_i
      metrics['incr_misses']           = curr_stats['incr_misses'].to_i
      metrics['incr_hits']             = curr_stats['incr_hits'].to_i
      metrics['decr_misses']           = curr_stats['decr_misses'].to_i
      metrics['decr_hits']             = curr_stats['decr_hits'].to_i
      metrics['cas_misses']            = curr_stats['cas_misses'].to_i
      metrics['cas_hits']              = curr_stats['cas_hits'].to_i
      metrics['cas_badval']            = curr_stats['cas_badval'].to_i
      metrics['touch_hits']            = curr_stats['touch_hits'].to_i
      metrics['touch_misses']          = curr_stats['touch_misses'].to_i
      metrics['auth_cmds']             = curr_stats['auth_cmds'].to_i
      metrics['auth_errors']           = curr_stats['auth_errors'].to_i
      metrics['bytes_read']            = curr_stats['bytes_read'].to_i
      metrics['bytes_written']         = curr_stats['bytes_written'].to_i
      metrics['limit_maxbytes']        = curr_stats['limit_maxbytes'].to_i
      metrics['accepting_conns']       = curr_stats['accepting_conns'].to_i
      metrics['threads']               = curr_stats['threads'].to_i
      metrics['conn_yields']           = curr_stats['conn_yields'].to_i
      metrics['hash_power_level']      = curr_stats['hash_power_level'].to_i
      metrics['hash_bytes']            = curr_stats['hash_bytes'].to_i
      metrics['hash_is_expanding']     = curr_stats['hash_is_expanding'].to_i
      metrics['expired_unfetched']     = curr_stats['expired_unfetched'].to_i
      metrics['evicted_unfetched']     = curr_stats['evicted_unfetched'].to_i
      metrics['bytes']                 = curr_stats['bytes'].to_i
      metrics['curr_items']            = curr_stats['curr_items'].to_i
      metrics['total_items']           = curr_stats['total_items'].to_i
      metrics['evictions']             = curr_stats['evictions'].to_i
      metrics['reclaimed']             = curr_stats['reclaimed'].to_i

      log "#{group_name} - #{mchost['name']} - #{Time.now.to_i} \n #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, mchost['name'], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_memcached_metric_group(metric_group, group_name, group_label, service)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating memcached metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label,
      frequency: @freq, service: service)
  else
    log 'Updating memcached metric group'
    metric_group.service = service
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << { type: 'ce_counter', name: 'uptime', position: 0,
                            label: 'Uptime', unit: 'Seconds' }
  metric_group.metrics << { type: 'ce_counter_f', name: 'rusage_user', position: 1,
                            label: 'Accumulated user time', unit: 'Seconds' }
  metric_group.metrics << { type: 'ce_counter_f', name: 'rusage_system', position: 2,
                            label: 'Accumulated system time', unit: 'Seconds' }
  metric_group.metrics << { type: 'ce_gauge', name: 'curr_connections', position: 3,
                            label: 'Open connections', unit: 'Connections' }
  metric_group.metrics << { type: 'ce_gauge', name: 'total_connections', position: 4,
                            label: 'Total connections', unit: 'Connections' }
  metric_group.metrics << { type: 'ce_gauge', name: 'connection_structures', position: 5,
                            label: 'Connection structures', unit: 'Structures' }
  metric_group.metrics << { type: 'ce_gauge', name: 'reserved_fds', position: 6,
                            label: 'Misc fds used internally', unit: 'FDs' }
  metric_group.metrics << { type: 'ce_counter', name: 'cmd_get', position: 7,
                            label: 'Retrieval requests', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cmd_set', position: 8,
                            label: 'Storage requests', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cmd_flush', position: 9,
                            label: 'Flush requests', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cmd_touch', position: 10,
                            label: 'Touch requests', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'get_hits', position: 11,
                            label: 'Keys requested and found present', unit: 'Keys' }
  metric_group.metrics << { type: 'ce_counter', name: 'get_misses', position: 12,
                            label: 'Keys requested and found missing', unit: 'Keys' }
  metric_group.metrics << { type: 'ce_counter', name: 'delete_misses', position: 13,
                            label: 'Deletion requests for missing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'delete_hits', position: 14,
                            label: 'Deletion requests for existing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'incr_misses', position: 15,
                            label: 'Incr requests against missing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'incr_hits', position: 16,
                            label: 'Incr requests against existing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'decr_misses', position: 17,
                            label: 'Decr requests against missing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'decr_hits', position: 18,
                            label: 'Decr requests against existing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cas_misses', position: 19,
                            label: 'CAS requests against missing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cas_hits', position: 20,
                            label: 'CAS requests against existing keys', unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'cas_badval', position: 21,
                            label: 'CAS requests for existing key & bad CAS value',
                            unit: 'Requests' }
  metric_group.metrics << { type: 'ce_counter', name: 'touch_hits', position: 22,
                            label: 'Keys touched with new expiration time', unit: 'Hits' }
  metric_group.metrics << { type: 'ce_counter', name: 'touch_misses', position: 23,
                            label: 'Keys touched and not found', unit: 'Misses' }
  metric_group.metrics << { type: 'ce_counter', name: 'auth_cmds', position: 24,
                            label: 'Auth commands handled', unit: 'Commands' }
  metric_group.metrics << { type: 'ce_counter', name: 'auth_errors', position: 25,
                            label: 'Failed authentications', unit: 'Authentications' }
  metric_group.metrics << { type: 'ce_counter', name: 'bytes_read', position: 26,
                            label: 'Bytes read', unit: 'b' }
  metric_group.metrics << { type: 'ce_counter', name: 'bytes_written', position: 27,
                            label: 'Bytes written', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge', name: 'limit_maxbytes', position: 28,
                            label: 'Bytes allowed for storage', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge', name: 'accepting_conns', position: 29,
                            label: 'Check if server is accepting connections' }
  metric_group.metrics << { type: 'ce_gauge', name: 'threads', position: 30,
                            label: 'Worker threads requested', unit: 'Threads' }
  metric_group.metrics << { type: 'ce_counter', name: 'conn_yields', position: 31,
                            label: 'Connections yielded to hit limit', unit: 'Connections' }
  metric_group.metrics << { type: 'ce_gauge', name: 'hash_power_level', position: 32,
                            label: 'Current size multiplier for hash table' }
  metric_group.metrics << { type: 'ce_gauge', name: 'hash_bytes', position: 33,
                            label: 'Bytes used by hash tables', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge', name: 'hash_is_expanding', position: 34,
                            label: 'Indicates if hash table is expanding' }
  metric_group.metrics << { type: 'ce_counter', name: 'expired_unfetched', position: 35,
                            label: 'Items pulled from LRU never used before expiring',
                            unit: 'Items' }
  metric_group.metrics << { type: 'ce_counter', name: 'evicted_unfetched', position: 36,
                            label: 'Items evicted from LRU that were never touched',
                            unit: 'Items' }
  metric_group.metrics << { type: 'ce_gauge', name: 'bytes', position: 37,
                            label: 'Bytes used', unit: 'b' }
  metric_group.metrics << { type: 'ce_gauge', name: 'curr_items', position: 38,
                            label: 'Current items stored', unit: 'Items' }
  metric_group.metrics << { type: 'ce_counter', name: 'total_items', position: 39,
                            label: 'Total items stored', unit: 'Items' }
  metric_group.metrics << { type: 'ce_counter', name: 'evictions', position: 40,
                            label: 'Items removed from cache to free memory', unit: 'Items' }
  metric_group.metrics << { type: 'ce_counter', name: 'reclaimed', position: 41,
                            label: 'No. of times entry stored using memory from expired entry' }
  metric_group.save
  metric_group
end

def create_memcached_dashboard(metric_group, name)
  log 'Creating new memcached Dashboard'
  metrics = metric_group.metrics || []

  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics,
                                    is_database: true, service: 'memcached')
end

def ensure_metric_group(metric_group, service)
  return ensure_memcached_metric_group(metric_group, @config[service]['group_name'],
    @config[service]['group_label'], service)
end

def create_dashboard(service, metric_group)
  create_memcached_dashboard(metric_group, @config[service]['dashboard'])
end

def monitor_service(service, metric_group)
  monitor_memcached(@config[service]['servers'], metric_group.name)
end

####################################################################################################

opts = GetoptLong.new(
  ['--help',      '-h', GetoptLong::NO_ARGUMENT],
  ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
  ['--verbose',   '-v', GetoptLong::NO_ARGUMENT],
  ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
  ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
  ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
  ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
)

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

unless CopperEgg::Api.apikey
  log 'You need to supply an apikey with the -k option or in the config.yml.'
  exit
end

if @services.empty?
  log 'No services listed in the config file.'
  log 'Nothing will be monitored!'
  exit
end

@freq = 60 unless [15, 60, 300, 900, 3600, 21_600].include?(@freq)
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
  raise CopperEggAgentError.new("Service #{service} not recognized") unless service == 'memcached'

  if @config[service] && !@config[service]['servers'].empty?
    begin
      log "Checking for existence of metric group for #{service}"
      if metric_groups.nil?
        metric_group = metric_groups.detect { |m| m.name == @config[service]['group_name'] }
      else
        metric_group = ensure_metric_group(metric_group, service)
      end
      raise "Could not create a metric group for #{service}" if metric_group.nil?

      log "Checking for existence of #{@config[service]['dashboard']}"
      dashboard = dashboards.nil? ? nil : dashboards.detect { |d| d.name == @config[service]['dashboard'] } ||
          create_dashboard(service, metric_group)
      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log 'Error while creating Metric group/dashboard'
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
        monitor_service(service, metric_group)
      rescue => e
        log "Error monitoring #{service}.  Retrying (#{retries}) more times..."
        log e.inspect if @debug
        log e.backtrace[0..30].join("\n") if @debug
        raise e if @debug
        sleep 2
        retries -= 1

        # reset retries counter if last failure was more than 10 minutes ago
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
