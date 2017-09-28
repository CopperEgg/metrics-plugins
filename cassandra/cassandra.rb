#!/usr/bin/env ruby
#
# CopperEgg cassandra monitoring
#

BASE_PATH = '/usr/local/copperegg/ucm-metrics/cassandra'
ENV['BUNDLE_GEMFILE'] = "#{BASE_PATH}/Gemfile"

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'


class CassandraMonitoring
  class CopperEggAgentError < Exception; end

  TIME_STRING = '%Y/%m/%d %H:%M:%S'.freeze
  UNITS_FACTOR = {
      'bytes' => 1,
      'KB' => 1024,
      'MB' => 1024**2,
      'GB' => 1024**3,
      'TB' => 1024**4,
      'KiB' => 1024,
      'MiB' => 1024**2,
      'GiB' => 1024**3,
      'TiB' => 1024**4
  }
  MAX_RETRIES = 30
  MAX_SETUP_RETRIES = 5

  def initialize
    config_file = "#{BASE_PATH}/config.yml"
    @apihost = nil
    @debug = false
    @freq = 60
    @interrupted = false
    @worker_pids = []
    @services = []

    # Look for config file
    @config = YAML.load(File.open(config_file))

    unless @config.nil?
      # load config
      if !@config['copperegg'].nil?
        CopperEgg::Api.apikey = @config['copperegg']['apikey'] unless
            @config['copperegg']['apikey'].nil? && CopperEgg::Api.apikey.nil?
        CopperEgg::Api.host = @config['copperegg']['apihost'] unless
            @config['copperegg']['apihost'].nil?
        @freq = @config['copperegg']['frequency'] unless @config['copperegg']['frequency'].nil?
        @services = @config['copperegg']['services']
      else
        log 'You have no copperegg entry in your config.yml!'
        log 'Edit your config.yml and restart.'
        exit
      end
    end
  end

  def run
    # get options
    opts = GetoptLong.new(
        ['--help',      '-h', GetoptLong::NO_ARGUMENT],
        ['--debug',     '-d', GetoptLong::NO_ARGUMENT],
        ['--config',    '-c', GetoptLong::REQUIRED_ARGUMENT],
        ['--apikey',    '-k', GetoptLong::REQUIRED_ARGUMENT],
        ['--frequency', '-f', GetoptLong::REQUIRED_ARGUMENT],
        ['--apihost',   '-a', GetoptLong::REQUIRED_ARGUMENT]
    )

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
        when '--frequency'
          @freq = arg.to_i
        when '--apihost'
          CopperEgg::Api.host = arg
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

    @freq = 60 unless [15, 60, 300, 900, 3600].include?(@freq)
    log "Update frequency set to #{@freq}s."

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
      # If we can't succeed with setup on the servcies, let's just error out
      raise e
    end

    @services.each do |service|
      next unless @config[service] && !@config[service]['clusters'].empty?
      begin
        log "Checking for existence of metric group for #{service}"
        metric_group = metric_groups.detect { |m| m.name == @config[service]['group_name'] } unless metric_groups.nil?
        if metric_group.nil?
          metric_group = ensure_cassandra_metric_group(metric_group, @config[service]['group_name'],
                                                    @config[service]['group_label'], service)
        end
        metric_group = ensure_metric_group(metric_group, service)
        raise "Could not create a metric group for #{service}" if metric_group.nil?
        log "Checking for existence of #{@config[service]['dashboard']}"
        dashboard = dashboards.nil? ? nil : dashboards.detect { |d| d.name == @config[service]['dashboard'] } ||
            create_dashboard(service, metric_group)
        log "Could not create a dashboard for #{service}" if dashboard.nil?
      rescue => e
        log e.message
        next
      end

      child_pid = fork do
        trap('INT') { child_interrupt unless @interrupted }
        trap('TERM') { child_interrupt unless @interrupted }
        last_failure = 0
        retries = MAX_RETRIES
        begin
          monitor_service(service, metric_group)
        rescue => e
          log "Error monitoring #{service}.  Retrying (#{retries}) more times..."
          log e.inspect.to_s
          log e.backtrace[0..30].join("\n") if @debug
          # updated 7-9-2013, removed the # before if @debug
          raise e if @debug
          sleep 2
          retries -= 1
          # reset retries counter if last failure was more than 10 minutes ago
          retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
          last_failure = Time.now.to_i
          retry if retries > 0
          raise e
        end
      end
      @worker_pids.push child_pid
    end

    # ... wait for all processes to exit ...
    p Process.waitall
  end

  def help
    puts 'usage: $0 args'
    puts 'Examples:'
    puts '  -c config.yml'
    puts '  -f 60                 (for 60s updates. Valid values: 15, 60, 300, 900, 3600)'
    puts '  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)'
    puts '  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])'
  end

  # Used to prefix the log message with a date.
  def log(str)
    str.split("\n").each do |line|
      puts "#{Time.now.strftime(TIME_STRING)} pid:#{Process.pid}> #{line}"
    end
    $stdout.flush
  rescue
    # do nothing -- just catches unimportant errors when we kill the process
    # and it's in the middle of logging or flushing.
  end

  def interruptible_sleep(seconds)
    seconds.times { sleep 1 unless @interrupted }
  end

  def child_interrupt
    # do child clean-up here
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

  def convert_to_bytes(size, unit)
    size.to_f * UNITS_FACTOR[unit]
  end

  def parse_info_stats(stats)
    hash = {}
    if stats
      stats.each_line do |line|
        if (m = line.match(/^Exceptions\s*:\s+([0-9]+)$/))
          hash['exceptions'] = m[1]
        elsif (m = line.match(/^Load\s*:\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes)$/))
          hash['load'] = convert_to_bytes(m[1], m[2])
        elsif (m = line.match(/^Key Cache\s*:\s+entries\s+([0-9.]+), size\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), capacity\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), ([0-9.]+) hits, ([0-9.]+) requests, (NaN|[0-9.]+) recent hit rate/))
          hash['key_cache_size'] = convert_to_bytes(m[2], m[3])
          hash['key_cache_capacity'] = convert_to_bytes(m[4], m[5])
          hash['key_cache_hits'] = m[6].to_i
          hash['key_cache_requests'] = m[7].to_i
          hash['key_cache_recent_hit_rate'] = m[8].to_f
        elsif (m = line.match(/^Row Cache\s*:\s+entries\s+([0-9.]+), size\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), capacity\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), ([0-9.]+) hits, ([0-9.]+) requests, (NaN|[0-9.]+) recent hit rate/))
          hash['row_cache_size'] = convert_to_bytes(m[2], m[3])
          hash['row_cache_capacity'] = convert_to_bytes(m[4], m[5])
          hash['row_cache_hits'] = m[6].to_i
          hash['row_cache_requests'] = m[7].to_i
          hash['row_cache_recent_hit_rate'] = m[8].to_f
        elsif (m = line.match(/^Counter Cache\s*:\s+entries\s+([0-9.]+), size\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), capacity\s+([0-9.]+)\s+([KMGT]B|[KMGT]iB|bytes), ([0-9.]+) hits, ([0-9.]+) requests, (NaN|[0-9.]+) recent hit rate/))
          hash['counter_cache_size'] = convert_to_bytes(m[2], m[3])
          hash['counter_cache_capacity'] = convert_to_bytes(m[4], m[5])
          hash['counter_cache_hits'] = m[6].to_i
          hash['counter_cache_requests'] = m[7].to_i
          hash['counter_cache_recent_hit_rate'] = m[8].to_f
        end
      end
    end
    hash
  rescue
    log 'Unable to parse info stats' if @debug
    return {}
  end

  def parse_table_stats(stats)
    hash = {}
    if stats
      temp_hash = {}
      temp_hash['read_count'] = 0
      temp_hash['write_count'] = 0
      temp_hash['bloom_filter_disk_space_used'] = 0
      temp_hash['bloom_filter_false_positive'] = 0
      temp_hash['live_disk_space_used'] = 0.0
      temp_hash['sstable_count'] = 0
      temp_hash['memtable_column_count'] = 0
      temp_hash['memtable_data_size'] = 0.0
      temp_hash['memtable_switch_count'] = 0
      temp_hash['total_disk_space_used'] = 0.0
      temp_hash['read_latency'] = 0.0
      temp_hash['write_latency'] = 0.0
      temp_hash['bloom_filter_false_ratio'] = { value: 0.0, count: 0 }
      temp_hash['compression_ratio'] = { value: 0.0, count: 0 }
      temp_hash['max_row_size'] = 0.0
      temp_hash['mean_row_size'] = { value: 0.0, count: 0 }
      temp_hash['min_row_size'] = 0.0

      stats.each_line do |line|
        next if line =~ /^Keyspace/
        if (m = line.match(/^\s*Read Count: ([0-9.]+)/))
          temp_hash['read_count'] += m[1].to_i
        elsif (m = line.match(/^\s*Write Count: ([0-9.]+)/))
          temp_hash['write_count'] += m[1].to_i
        elsif (m = line.match(/^\s*Write Latency: ([0-9.]+)/))
          temp_hash['write_latency'] += m[1].to_f
        elsif (m = line.match(/^\s*Read Latency: ([0-9.]+)/))
          temp_hash['read_latency'] += m[1].to_f
        elsif (m = line.match(/^\s*Bloom filter space used: ([0-9.]+)/))
          temp_hash['bloom_filter_disk_space_used'] += m[1].to_f
        elsif (m = line.match(/^\s*Bloom filter false positives: ([0-9.]+)/))
          temp_hash['bloom_filter_false_positive'] += m[1].to_i
        elsif (m = line.match(/^\s*Space used (live): ([0-9.]+)/))
          temp_hash['live_disk_space_used'] += m[1].to_f
        elsif (m = line.match(/^\s*Space used (total):  ([0-9.]+)/))
          temp_hash['total_disk_space_used'] += m[1].to_f
        elsif (m = line.match(/^\s*SSTable count: ([0-9.]+)/))
          temp_hash['sstable_count'] += m[1].to_i
        elsif (m = line.match(/^\s*Memtable cell count: ([0-9.]+)/))
          temp_hash['memtable_column_count'] += m[1].to_i
        elsif (m = line.match(/^\s*Memtable data size: ([0-9.]+)/))
          temp_hash['memtable_data_size'] += m[1].to_f
        elsif (m = line.match(/^\s*Memtable switch count: ([0-9.]+)/))
          temp_hash['memtable_switch_count'] += m[1].to_i
        elsif (m = line.match(/^\s*Bloom filter false ratio: ([0-9.]+)/))
          temp_hash['bloom_filter_false_ratio'][:value] += m[1].to_f
          temp_hash['bloom_filter_false_ratio'][:count] += 1
        elsif (m = line.match(/^\s*SSTable Compression Ratio: ([0-9.]+)/))
          temp_hash['compression_ratio'][:value] += m[1].to_f
          temp_hash['compression_ratio'][:count] += 1
        elsif (m = line.match(/^\s*Compacted partition minimum bytes: ([0-9.]+)/))
          temp_hash['max_row_size'] = m[1].to_f if m[1].to_f > temp_hash['max_row_size']
        elsif (m = line.match(/^\s*Compacted partition maximum bytes: ([0-9.]+)/))
          temp_hash['min_row_size'] = m[1].to_f if m[1].to_f < temp_hash['min_row_size']
        elsif (m = line.match(/^\s*Compacted partition mean bytes: ([0-9.]+)/))
          temp_hash['mean_row_size'][:value] += m[1].to_f
          temp_hash['mean_row_size'][:count] += 1
        end
      end

      hash['read_count'] = temp_hash['read_count']
      hash['write_count'] = temp_hash['write_count']
      hash['write_latency'] = temp_hash['write_latency']
      hash['read_latency'] = temp_hash['read_latency']
      hash['bloom_filter_disk_space_used'] = temp_hash['bloom_filter_disk_space_used']
      hash['bloom_filter_false_positive'] = temp_hash['bloom_filter_false_positive']
      hash['live_disk_space_used'] = temp_hash['live_disk_space_used']
      hash['total_disk_space_used'] = temp_hash['total_disk_space_used']
      hash['sstable_count'] = temp_hash['sstable_count']
      hash['memtable_column_count'] = temp_hash['memtable_column_count']
      hash['memtable_data_size'] = temp_hash['memtable_data_size']
      hash['memtable_switch_count'] = temp_hash['memtable_switch_count']
      hash['bloom_filter_false_ratio'] = temp_hash['bloom_filter_false_ratio'][:count] > 0 ?
          temp_hash['bloom_filter_false_ratio'][:value] / temp_hash['bloom_filter_false_ratio'][:count] : 0
      hash['compression_ratio'] = temp_hash['compression_ratio'][:count] > 0 ?
          temp_hash['compression_ratio'][:value] / temp_hash['compression_ratio'][:count] : 0
      hash['min_row_size'] = temp_hash['min_row_size']
      hash['max_row_size'] = temp_hash['max_row_size']
      hash['mean_row_size'] = temp_hash['mean_row_size'][:count] > 0 ?
          temp_hash['mean_row_size'][:value] / temp_hash['mean_row_size'][:count] : 0
    end
    hash
  rescue
    log 'Unable to parse table stats' if @debug
    return {}
  end

  def parse_tp_stats(stats)
    hash = {}
    if stats
      temp_hash = {}
      temp_hash['active'] = 0
      temp_hash['pending'] = 0
      temp_hash['completed'] = 0
      temp_hash['currently_blocked'] = 0
      temp_hash['blocked'] = 0
      stats.each_line do |line|
        next if line =~ /^Pool Name/
        next if line =~ /^READ/
        next if line =~ /^_TRACE/
        next if line =~ /^RANGE_SLICE/
        next if line =~ /^MUTATION/
        next if line =~ /^COUNTER_MUTATION/
        next if line =~ /^REQUEST_RESPONSE/
        next if line =~ /^PAGED_RANGE/
        next if line =~ /^READ_REPAIR/
        if (m = line.match(/^(\w+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$/))
          # (thread, active, pending, completed, currently_blocked, blocked) = m.captures
          temp_hash['active'] += m[2].to_i
          temp_hash['pending'] += m[3].to_i
          temp_hash['completed'] += m[4].to_i
          temp_hash['currently_blocked'] += m[5].to_i
          temp_hash['blocked'] += m[6].to_i
        end
      end
      hash['active_tasks'] = temp_hash['active']
      hash['pending_tasks'] = temp_hash['pending']
      hash['completed_tasks'] = temp_hash['completed']
      hash['currently_blocked_tasks'] = temp_hash['currently_blocked']
      hash['total_blocked_tasks'] = temp_hash['blocked']
    end
    hash
  rescue
    log 'Unable to parse tp stats' if @debug
    return {}
  end

  def get_cassandra_stats(host = 'localhost', port = '7199', user = nil, pw = nil)
    metrics = {}
    user_info = user && pw ? "-u #{user} -pw #{pw}" : ''

    metrics['info'] = `nodetool -h #{host} -p #{port} #{user_info} info`
    metrics['table_stats'] = `nodetool -h #{host} -p #{port} #{user_info} tablestats`
    metrics['tp_stats'] = `nodetool -h #{host} -p #{port} #{user_info} tpstats`

    metrics
  rescue
    log "Unable to connect to Cassandra nodetool at #{hostname}:#{port}"
    return nil
  end

  def parse_cassandra_stats(stats)
    hash = {}
    if stats
      hash.merge!(parse_info_stats(stats['info'])) if stats['info']
      hash.merge!(parse_table_stats(stats['table_stats'])) if stats['table_stats']
      hash.merge!(parse_tp_stats(stats['tp_stats'])) if stats['tp_stats']
    end
    hash
  end

  def monitor_cassandra(cassandra_cluster, group_name)
    log 'Monitoring cassandra databases: '
    return if @interrupted

    until @interrupted
      return if @interrupted

      cassandra_cluster.each do |mhost|
        return if @interrupted
        hash = parse_cassandra_stats(get_cassandra_stats(mhost['hostname'], mhost['port'],
                                                         mhost['username'], mhost['password']))

        metrics = {}
        metrics['exceptions']                           = hash['exceptions']
        metrics['load']                                 = hash['load']
        metrics['key_cache_size']                       = hash['key_cache_size']
        metrics['key_cache_capacity']                   = hash['key_cache_capacity']
        metrics['key_cache_hits']                       = hash['key_cache_hits']
        metrics['key_cache_requests']                   = hash['key_cache_requests']
        metrics['key_cache_recent_hit_rate']            = hash['key_cache_recent_hit_rate']
        metrics['row_cache_size']                       = hash['row_cache_size']
        metrics['row_cache_capacity']                   = hash['row_cache_capacity']
        metrics['row_cache_hits']                       = hash['row_cache_hits']
        metrics['row_cache_requests']                   = hash['row_cache_requests']
        metrics['row_cache_recent_hit_rate']            = hash['row_cache_recent_hit_rate']
        metrics['counter_cache_size']                   = hash['counter_cache_size']
        metrics['counter_cache_capacity']               = hash['counter_cache_capacity']
        metrics['counter_cache_hits']                   = hash['counter_cache_hits']
        metrics['counter_cache_requests']               = hash['counter_cache_requests']
        metrics['counter_cache_recent_hit_rate']        = hash['counter_cache_recent_hit_rate']
        metrics['active_tasks']                         = hash['active_tasks']
        metrics['pending_tasks']                        = hash['pending_tasks']
        metrics['completed_tasks']                      = hash['completed_tasks']
        metrics['currently_blocked_tasks']              = hash['currently_blocked_tasks']
        metrics['total_blocked_tasks']                  = hash['total_blocked_tasks']
        metrics['read_count']                           = hash['read_count']
        metrics['write_count']                          = hash['write_count']
        metrics['write_latency']                        = hash['write_latency']
        metrics['read_latency']                         = hash['read_latency']
        metrics['bloom_filter_disk_space_used']         = hash['bloom_filter_disk_space_used']
        metrics['bloom_filter_false_positive']          = hash['bloom_filter_false_positive']
        metrics['live_disk_space_used']                 = hash['live_disk_space_used']
        metrics['total_disk_space_used']                = hash['total_disk_space_used']
        metrics['sstable_count']                        = hash['sstable_count']
        metrics['memtable_column_count']                = hash['memtable_column_count']
        metrics['memtable_data_size']                   = hash['memtable_data_size']
        metrics['memtable_switch_count']                = hash['memtable_switch_count']
        metrics['bloom_filter_false_ratio']             = hash['bloom_filter_false_ratio']
        metrics['compression_ratio']                    = hash['compression_ratio']
        metrics['min_row_size']                         = hash['min_row_size']
        metrics['max_row_size']                         = hash['max_row_size']
        metrics['mean_row_size']                        = hash['mean_row_size']

        # puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}"
        CopperEgg::MetricSample.save(group_name, "#{mhost['name']}",
                                     Time.now.to_i, metrics)
      end
      interruptible_sleep @freq
    end

  end

  def ensure_cassandra_metric_group(metric_group, group_name, group_label, service)
    if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
      log 'Creating cassandra metric group'
      metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label,
        frequency: @freq, service: service)
    else
      log 'Updating cassandra metric group'
      metric_group.frequency = @freq
    end

    metric_group.metrics = []
    metric_group.metrics << { type: 'ce_gauge',   name: 'exceptions', unit: 'Exceptions' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'load', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'key_cache_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'key_cache_capacity', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'key_cache_hits', unit: 'Hits' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'key_cache_requests', unit: 'Requests' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'key_cache_recent_hit_rate', unit: '' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'row_cache_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'row_cache_capacity', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'row_cache_hits', unit: 'Hits' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'row_cache_requests', unit: 'Requests' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'row_cache_recent_hit_rate', unit: '' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'counter_cache_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'counter_cache_capacity', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'counter_cache_hits', unit: 'Hits' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'counter_cache_requests', unit: 'Requests' }
    metric_group.metrics << { type: 'ce_gauge_f', name: 'counter_cache_recent_hit_rate', unit: '' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'active_tasks', unit: 'Tasks' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'pending_tasks', unit: 'Tasks' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'completed_tasks', unit: 'Tasks' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'currently_blocked_tasks', unit: 'Tasks' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'total_blocked_tasks', unit: 'Tasks' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'read_count', unit: 'Requests' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'write_count', unit: 'Requests' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'write_latency', unit: 'ms' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'read_latency', unit: 'ms' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'bloom_filter_disk_space_used',
                              unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'bloom_filter_false_positive',
                              unit: 'False Positives' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'live_disk_space_used', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'total_disk_space_used', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'sstable_count', unit: 'Tables' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'memtable_column_count', unit: 'Columns' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'memtable_data_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'memtable_switch_count', unit: 'Times' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'bloom_filter_false_ratio', unit: '' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'compression_ratio', unit: '' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'min_row_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'max_row_size', unit: 'Bytes' }
    metric_group.metrics << { type: 'ce_gauge',   name: 'mean_row_size', unit: 'Bytes' }

    metric_group.save
    metric_group
  end

  def create_cassandra_dashboard(metric_group, name)
    log 'Creating new Cassandra Dashboard'
    metrics = metric_group.metrics || []

    # Create a dashboard for all identifiers:
    CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics,
                                      is_database: true, service: 'cassandra')
  end

  def ensure_metric_group(metric_group, service)
    if service == 'cassandra'
      return ensure_cassandra_metric_group(metric_group, @config[service]['group_name'],
        @config[service]['group_label'], service)
    else
      raise CopperEggAgentError.new("Service #{service} not recognized")
    end
  end

  def create_dashboard(service, metric_group)
    if service == 'cassandra'
      create_cassandra_dashboard(metric_group, @config[service]['dashboard'])
    else
      raise CopperEggAgentError.new("Service #{service} not recognized")
    end
  end

  def monitor_service(service, metric_group)
    if service == 'cassandra'
      monitor_cassandra(@config[service]['clusters'], metric_group.name)
    else
      raise CopperEggAgentError.new("Service #{service} not recognized")
    end
  end

end

CassandraMonitoring.new.run
