#!/usr/bin/env ruby
#
# Copyright 2012 IDERA.  All rights reserved.
#

require 'rubygems'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'

class CopperEggAgentError < Exception; end

####################################################################

def help
  puts "usage: $0 args"
  puts "Examples:"
  puts "  -c config.yml"
  puts "  -f 60                 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)"
  puts "  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)"
  puts "  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])"
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

def interruptible_sleep(seconds)
  seconds.times {|i| sleep 1 if !@interrupted}
end

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

config_file = "config.yml"
@apihost = nil
@debug = false
@verbose = false
@freq = 60  # update frequency in seconds
@interrupted = false
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
    @verbose = true
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
    log "Using api host #{arg}"
  end
end

# Look for config file
@config = YAML.load(File.open(config_file))

if !@config.nil?
  # load config
  if !@config["copperegg"].nil?
    CopperEgg::Api.apikey = @config["copperegg"]["apikey"] if !@config["copperegg"]["apikey"].nil? && CopperEgg::Api.apikey.nil?
    CopperEgg::Api.host = @config["copperegg"]["host"] if !@config["copperegg"]["host"].nil?
    @freq = @config["copperegg"]["frequency"] if !@config["copperegg"]["frequency"].nil?
    @services = @config['copperegg']['services']
  else
    log "You have no copperegg entry in your config.yml!"
    log "Edit your config.yml and restart."
    exit
  end
end

if @config['apache'] && @config['apache']['logformat']
  require 'request_log_analyzer'

  @apache_log_format = '%h %l %u %t "%r" %>s %b %D'
  @apache_log_format = @config['apache']['logformat'] if !@config['apache']['logformat'].empty?

  @apache_line_def = RequestLogAnalyzer::FileFormat::Apache.access_line_definition(@apache_log_format)
  @apache_log_request = RequestLogAnalyzer::FileFormat::Apache.new.request
end


if CopperEgg::Api.apikey.nil?
  log "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

if @services.length == 0
  log "No services listed in the config file."
  log "Nothing will be monitored!"
  exit
end

@freq = 60 if ![5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."

####################################################################

def connect_to_redis(uri, attempts=10)
  splituri = URI.parse(uri)
  connect_try_count = 0
  redis = nil
  begin
    redis = Redis.new(:host => splituri.host, :port => splituri.port, :password => splituri.password)
  rescue Exception => e
    connect_try_count += 1
    if connect_try_count > attempts
      log "#{e.inspect}"
      log e.backtrace[0..30].join("\n") if @debug
      raise e
    end
    sleep 0.5
  retry
  end
  return redis
end

def monitor_redis(redis_servers, group_name)
  require 'redis'
  log "Monitoring Redis: "
  
  while !@interrupted do
    return if @interrupted

    redis_servers.each do |rhost|
      return if @interrupted

      label = rhost["name"]
      rhostname = rhost["hostname"]
      rport = rhost["port"]
      rpass = rhost["password"]

      if rpass.nil?
        redis_uri = "redis://#{rhostname}:#{rport}"
      else
        redis_uri = "redis://redis:#{rpass}@#{rhostname}:#{rport}"
      end

      begin
        redis = connect_to_redis(redis_uri)
        rinfo = redis.info()
      rescue Exception => e
        log "Error getting Redis stats from: #{label} [skipping]"
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        next
      end

      metrics = {}
      metrics["uptime"]                       = rinfo["uptime_in_seconds"].to_i
      metrics["used_cpu_sys"]                 = rinfo["used_cpu_sys"].to_f*100
      metrics["used_cpu_user"]                = rinfo["used_cpu_user"].to_f*100
      metrics["connected_clients"]            = rinfo["connected_clients"].to_i
      metrics["connected_slaves"]             = rinfo["connected_slaves"].to_i
      metrics["blocked_clients"]              = rinfo["blocked_clients"].to_i
      metrics["used_memory"]                  = rinfo["used_memory"].to_i
      metrics["used_memory_rss"]              = rinfo["used_memory_rss"].to_i
      metrics["used_memory_peak"]             = rinfo["used_memory_peak"].to_i
      metrics["mem_fragmentation_ratio"]      = rinfo["mem_fragmentation_ratio"].to_f
      metrics["changes_since_last_save"]      = rinfo["changes_since_last_save"].to_i
      metrics["total_connections_received"]   = rinfo["total_connections_received"].to_i
      metrics["total_commands_processed"]     = rinfo["total_commands_processed"].to_i
      metrics["expired_keys"]                 = rinfo["expired_keys"].to_i
      metrics["evicted_keys"]                 = rinfo["evicted_keys"].to_i
      metrics["keyspace_hits"]                = rinfo["keyspace_hits"].to_i
      metrics["keyspace_misses"]              = rinfo["keyspace_misses"].to_i
      metrics["pubsub_channels"]              = rinfo["pubsub_channels"].to_i
      metrics["pubsub_patterns"]              = rinfo["pubsub_patterns"].to_i
      metrics["latest_fork_usec"]             = rinfo["latest_fork_usec"].to_i
      metrics["keys"]                         = (rinfo["db0"] ? rinfo["db0"].split(',')[0].split('=')[1].to_i : 0)
      metrics["expires"]                      = (rinfo["db0"] ? rinfo["db0"].split(',')[1].split('=')[1].to_i : 0)

      # Uncomment these lines if you are using Redis 2.6:
      #if !rinfo["redis_version"].match("2.4")
        #metrics["used_memory_lua"]            = rinfo["used_memory_lua"].to_i
        #metrics["rdb_changes_since_last_save"]= rinfo["rdb_changes_since_last_save"].to_i
        #metrics["instantaneous_ops_per_sec"]  = rinfo["instantaneous_ops_per_sec"].to_i
        #metrics["rejected_connections"]       = rinfo["rejected_connections"].to_i
      #end
      # End Redis 2.6 metrics

      redis.client.disconnect

      puts "#{group_name} - #{label} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, label, Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_redis_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating Redis metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating Redis metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_counter", :name => "uptime",                     :unit => "Seconds"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "used_cpu_sys",               :unit => "Seconds"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "used_cpu_user",              :unit => "Seconds"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "connected_clients",          :unit => "Clients"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "connected_slaves",           :unit => "Slaves"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "blocked_clients",            :unit => "Clients"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "used_memory",                :unit => "Bytes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "used_memory_rss",            :unit => "Bytes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "used_memory_peak",           :unit => "Bytes"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "mem_fragmentation_ratio"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "changes_since_last_save",    :unit => "Changes"}
  metric_group.metrics << {:type => "ce_counter", :name => "total_connections_received", :unit => "Connections"}
  metric_group.metrics << {:type => "ce_counter", :name => "total_commands_processed",   :unit => "Commands"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "expired_keys",               :unit => "Keys"}
  metric_group.metrics << {:type => "ce_counter", :name => "keyspace_hits",              :unit => "Hits"}
  metric_group.metrics << {:type => "ce_counter", :name => "keyspace_misses",            :unit => "Misses"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "pubsub_channels",            :unit => "Channels"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "pubsub_patterns",            :unit => "Patterns"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "latest_fork_usec",           :unit => "usec"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "keys",                       :unit => "Keys"}
  metric_group.metrics << {:type => "ce_counter", :name => "evicted_keys",               :unit => "Keys"}
  metric_group.metrics << {:type => "ce_counter", :name => "expires",                    :unit => "Keys"}

  # Uncomment these lines if you are using Redis 2.6:
  #metric_group.metrics << {:type => "ce_counter", :name => "used_memory_lua",            :unit => "Bytes"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "rdb_changes_since_last_save",:unit => "Changes"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "instantaneous_ops_per_sec",  :unit => "Ops"}
  #metric_group.metrics << {:type => "ce_counter", :name => "rejected_connections",       :unit => "Connections"}
  # End Redis 2.6 metrics

  metric_group.save
  metric_group
end

def create_redis_dashboard(metric_group, name, server_list)
  log "Creating new Redis Dashboard"
  servers = server_list.map { |server_entry| server_entry["name"] }
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
  # Create a dashboard for only the servers we've defined:
  #CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => servers, :metrics => metrics)
end

####################################################################

def connect_to_mysql(hostname, user, pw, db, socket=nil)
  client = Mysql2::Client.new(:host => hostname,
                              :username => user,
                              :password => pw,
                              :database => db,
                              :socket => socket)
    
  return client
end

def monitor_mysql(mysql_servers, group_name)
  require 'mysql2'
  log "Monitoring MySQL: "
  return if @interrupted

  while !@interrupted do
    return if @interrupted

    mysql_servers.each do |mhost|
      return if @interrupted

      begin
        mysql = Mysql2::Client.new(:host     => mhost["hostname"],
                                   :username => mhost["username"],
                                   :password => mhost["password"],
                                   :database => mhost["database"],
                                   :socket   => mhost["socket"],
                                   :port     => mhost["port"])
        mstats = mysql.query('SHOW GLOBAL STATUS;')

      rescue Exception => e
        log "Error getting MySQL stats from: #{mhost['hostname']} [skipping]"
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        next
      end

      minfo = {}

      mstats.each do |row|
        minfo[row["Variable_name"]] = row["Value"]
      end

      metrics = {}
      metrics["Threads_connected"]            = minfo["Threads_connected"].to_i
      metrics["Created_tmp_disk_tables"]      = minfo["Created_tmp_disk_tables"].to_i
      metrics["Qcache_hits"]                  = minfo["Qcache_hits"].to_i
      metrics["Queries"]                      = minfo["Queries"].to_i
      metrics["Slow_queries"]                 = minfo["Slow_queries"].to_i
      metrics["Bytes_received"]               = minfo["Bytes_received"].to_i
      metrics["Bytes_sent"]                   = minfo["Bytes_sent"].to_i
      metrics["Com_insert"]                   = minfo["Com_insert"].to_i
      metrics["Com_select"]                   = minfo["Com_select"].to_i
      metrics["Com_update"]                   = minfo["Com_update"].to_i

      #
      # Extra mysql metrics.
      # Uncomment these, or add your own, if you want that much more mysql data
      #
      #metrics["Handler_read_first"]           = minfo["Handler_read_first"].to_i
      #metrics["Innodb_buffer_pool_wait_free"] = minfo["Innodb_buffer_pool_wait_free"].to_i
      #metrics["Innodb_log_waits"]             = minfo["Innodb_log_waits"].to_i
      #metrics["Innodb_data_read"]             = minfo["Innodb_data_read"].to_i
      #metrics["Innodb_data_written"]          = minfo["Innodb_data_written"].to_i
      #metrics["Innodb_data_pending_fsyncs"]   = minfo["Innodb_data_pending_fsyncs"].to_i
      #metrics["Innodb_data_pending_reads"]    = minfo["Innodb_data_pending_reads"].to_i
      #metrics["Innodb_data_pending_writes"]   = minfo["Innodb_data_pending_writes"].to_i
      #metrics["Innodb_os_log_pending_fsyncs"] = minfo["Innodb_os_log_pending_fsyncs"].to_i
      #metrics["Innodb_os_log_pending_writes"] = minfo["Innodb_os_log_pending_writes"].to_i
      #metrics["Innodb_os_log_written"]        = minfo["Innodb_os_log_written"].to_i
      #metrics["Qcache_lowmem_prunes"]         = minfo["Qcache_lowmem_prunes"].to_i
      #metrics["Key_reads"]                    = minfo["Key_reads"].to_i
      #metrics["Key_writes"]                   = minfo["Key_writes"].to_i
      #metrics["Max_used_connections"]         = minfo["Max_used_connections"].to_i
      #metrics["Open_tables"]                  = minfo["Open_tables"].to_i
      #metrics["Open_files"]                   = minfo["Open_files"].to_i
      #metrics["Select_full_join"]             = minfo["Select_full_join"].to_i
      #metrics["Uptime"]                       = minfo["Uptime"].to_i
      #metrics["Table_locks_immediate"]        = minfo["Table_locks_immediate"].to_i
      #metrics["Com_alter_db"]                 = minfo["Com_alter_db"].to_i
      #metrics["Com_create_db"]                = minfo["Com_create_db"].to_i
      #metrics["Com_delete"]                   = minfo["Com_delete"].to_i
      #metrics["Com_drop_db"]                  = minfo["Com_drop_db"].to_i

      mysql.close

      puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, mhost["name"], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_mysql_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating MySQL metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating MySQL metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge",   :name => "Threads_connected",            :unit => "Threads"}
  metric_group.metrics << {:type => "ce_counter", :name => "Created_tmp_disk_tables",      :unit => "Tables"}
  metric_group.metrics << {:type => "ce_counter", :name => "Qcache_hits",                  :unit => "Hits"}
  metric_group.metrics << {:type => "ce_counter", :name => "Queries",                      :unit => "Queries"}
  metric_group.metrics << {:type => "ce_counter", :name => "Slow_queries",                 :unit => "Slow Queries"}
  metric_group.metrics << {:type => "ce_counter", :name => "Bytes_received",               :unit => "Bytes"}
  metric_group.metrics << {:type => "ce_counter", :name => "Bytes_sent",                   :unit => "Bytes"}
  metric_group.metrics << {:type => "ce_counter", :name => "Com_insert",                   :unit => "Commands"}
  metric_group.metrics << {:type => "ce_counter", :name => "Com_select",                   :unit => "Commands"}
  metric_group.metrics << {:type => "ce_counter", :name => "Com_update",                   :unit => "Commands"}

  #
  # Extra mysql metrics.
  # Uncomment these, or add your own, if you want that much more mysql data
  #
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Handler_read_first",           :unit => "Reads"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_buffer_pool_wait_free"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_log_waits",             :unit => "Waits"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Innodb_data_read",             :unit => "Bytes"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Innodb_data_written",          :unit => "Bytes"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_data_pending_fsyncs",   :unit => "FSyncs"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_data_pending_reads",    :unit => "Reads"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_data_pending_writes",   :unit => "Writes"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_os_log_pending_fsyncs", :unit => "FSyncs"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Innodb_os_log_pending_writes", :unit => "Writes"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Innodb_os_log_written"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Qcache_lowmem_prunes",         :unit => "Prunes"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Key_reads",                    :unit => "Reads"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Key_writes",                   :unit => "Writes"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Max_used_connections",         :unit => "Connections"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Open_tables",                  :unit => "Tables"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Open_files",                   :unit => "Files"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Select_full_join"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Uptime",                       :unit => "Seconds"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "Table_locks_immediate"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Com_alter_db",                 :unit => "Commands"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Com_create_db",                :unit => "Commands"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Com_delete",                   :unit => "Commands"}
  #metric_group.metrics << {:type => "ce_counter", :name => "Com_drop_db",                  :unit => "Commands"}
  metric_group.save
  metric_group
end

def create_mysql_dashboard(metric_group, name, server_list)
  log "Creating new MySQL/RDS Dashboard"
  servers = server_list.map {|server_entry| server_entry["name"]}
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
  # Create a dashboard for only the servers we've defined:
  #CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => servers, :metrics => metrics)
end

####################################################################

def monitor_apache(apache_servers, group_name)
  log "Monitoring Apache: "
  return if @interrupted

  while !@interrupted do
    return if @interrupted

    apache_servers.each do |ahost|
      return if @interrupted

      begin
        uri = URI.parse("#{ahost['url']}/server-status?auto")
        response = Net::HTTP.get_response(uri)
        if response.code != "200"
          return nil
        end

        astats = response.body.split(/\r*\n/)

      rescue Exception => e
        log "Error getting Apache stats from: #{ahost['url']} [skipping]"
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        next
      end

      ainfo = {}

      astats.each do |row|
        name, value = row.split(": ")
        ainfo[name] = value
      end

      avg_duration = nil
      apache_log_file = ahost['logfile']
      if @config['apache']['logformat'] && apache_log_file
        tot_duration = 0.0
        tot_reqs = 0

        # number of lines to read from the apache log.  It's possible we won't get all of them
        # if there are more than 100 requests per second, but it's still a pretty big sample size
        # that will yeild a close-enough number for all practical purposes
        tail_cnt = @freq * 100

        lines = `tail -n #{tail_cnt} #{apache_log_file}`
        lines.each_line do |line|
          #p line
          matches = @apache_line_def.matches(line)
          vals = @apache_line_def.convert_captured_values(matches[:captures], @apache_log_request) if matches
          ts_s = vals[:timestamp].to_s if vals
          next if ts_s.nil?

          # convert ts_s from hideous format YYYYMMDDhhmmss to a real time
          # and for whatever reason, RequestLogAnalyzer uses localtime, not gmt
          ts = Time.local(ts_s[0..3].to_i, ts_s[4..5].to_i, ts_s[6..7].to_i, ts_s[8..9].to_i, ts_s[10..11].to_i, ts_s[12..13].to_i)
          #p "ts=#{ts} now=#{Time.now}"
          next if ts.to_i < (Time.now.to_i - @freq)
          if vals[:duration]
            tot_duration += vals[:duration].to_f
            tot_reqs += 1
          end
        end

        avg_duration = tot_duration.to_f / tot_reqs.to_f
        avg_duration = 0.0 if avg_duration.nan? || avg_duration.infinite?
        p "tot_duration = #{tot_duration}; tot_reqs = #{tot_reqs}; avg_duration = #{avg_duration}" if @debug
      end



      metrics = {}
      metrics["total_accesses"]               = ainfo["Total Accesses"].to_i
      metrics["total_kbytes"]                 = ainfo["Total kBytes"].to_i
      metrics["cpu_load"]                     = ainfo["CPULoad"].to_f*100
      metrics["uptime"]                       = ainfo["Uptime"].to_i
      metrics["request_per_sec"]              = ainfo["ReqPerSec"].to_f
      metrics["bytes_per_sec"]                = ainfo["BytesPerSec"].to_i
      metrics["bytes_per_request"]            = ainfo["BytesPerReq"].to_f
      metrics["busy_workers"]                 = ainfo["BusyWorkers"].to_i
      metrics["idle_workers"]                 = ainfo["IdleWorkers"].to_i

      metrics["avg_request_duration"]         = avg_duration.to_f if avg_duration

      # Uncomment these lines if you are using apache 2.4+
      #metrics["connections_total"]            = ainfo["ConnsTotal"].to_i
      #metrics["connections_async_writing"]    = ainfo["ConnsAsyncWriting"].to_i
      #metrics["connections_async_keepalive"]  = ainfo["ConnsAsyncKeepAlive"].to_i
      #metrics["connections_async_closing"]    = ainfo["ConnsAsyncClosing"].to_i
      # End apache 2.4+ metrics

      puts "#{group_name} - #{ahost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, ahost["name"], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_apache_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating Apache metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating Apache metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_counter", :name => "total_accesses",              :unit => "Accesses"}
  metric_group.metrics << {:type => "ce_counter", :name => "total_kbytes",                :unit => "kBytes"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "cpu_load",                    :unit => "Percent"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "uptime",                      :unit => "Seconds"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "request_per_sec",             :unit => "Req/s"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "bytes_per_sec",               :unit => "Bytes/s"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "bytes_per_request",           :unit => "Bytes/Req"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "busy_workers",                :unit => "Busy Workers"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "idle_workers",                :unit => "Idle Workers"}

  # Uncomment these lines if you are using apache 2.4+
  #metric_group.metrics << {:type => "ce_gauge",   :name => "connections_total",           :unit => "Connections"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "connections_async_writing",   :unit => "Connections"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "connections_async_keepalive", :unit => "Connections"}
  #metric_group.metrics << {:type => "ce_gauge",   :name => "connections_async_closing",   :unit => "Connections"}
  # End apache 2.4+ metrics

  if @config['apache']['logformat']
    metric_group.metrics << {:type => "ce_gauge_f", :name => "avg_request_duration",     :unit => "Seconds"}
  end

  metric_group.save
  metric_group
end

def create_apache_dashboard(metric_group, name, server_list)
  log "Creating new Apache Dashboard"
  servers = server_list.map {|server_entry| server_entry["name"]}
  metrics = metric_group.metrics || []
  metrics << "avg_request_duration" if @config['apache']['logformat']

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
  # Create a dashboard for only the servers we've defined:
  #CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => servers, :metrics => metrics)
end

####################################################################

def monitor_nginx(nginx_servers, group_name)
  log "Monitoring Nginx: "
  return if @interrupted

  while !@interrupted do
    return if @interrupted

    log "Checking servers #{nginx_servers.inspect}"
    nginx_servers.each do |nhost|
      return if @interrupted

      begin
        log "Testing #{nhost['url']}/nginx_status" if @verbose
        uri = URI.parse("#{nhost['url']}/nginx_status")
        response = Net::HTTP.get_response(uri)
        log "    code: #{response.code}" if @verbose
        log "    head: #{response.header.to_hash}" if @verbose
        log "    body: #{response.body}" if @verbose
        if response.code != "200"
          log "    whoops! non-200 response code from #{nhost['url']}/nginx_status"
          log "    SKIPPING"
          next
        end

        nstats = response.body.split(/\r*\n/)

      rescue Exception => e
        log "Error getting Nginx stats from: #{nhost['url']} [skipping]"
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        next
      end

      metrics = {}
      metrics["active_connections"]    = nstats[0].split(": ")[1].to_i
      metrics["connections_accepts"]   = nstats[2].lstrip.split(/\s+/)[0].to_i
      metrics["connections_handled"]   = nstats[2].lstrip.split(/\s+/)[1].to_i
      metrics["connections_requested"] = nstats[2].lstrip.split(/\s+/)[2].to_i
      metrics["reading"]               = nstats[3].lstrip.split(/\s+/)[1].to_i
      metrics["writing"]               = nstats[3].lstrip.split(/\s+/)[3].to_i
      metrics["waiting"]               = nstats[3].lstrip.split(/\s+/)[5].to_i

      puts "#{group_name} - #{nhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, nhost["name"], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_nginx_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating Nginx metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating Nginx metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => "ce_gauge",   :name => "active_connections",     :unit => "Connections"}
  metric_group.metrics << {:type => "ce_counter", :name => "connections_accepts",    :unit => "Connections"}
  metric_group.metrics << {:type => "ce_counter", :name => "connections_handled",    :unit => "Connections"}
  metric_group.metrics << {:type => "ce_counter", :name => "connections_requested",  :unit => "Connections"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "reading",                :unit => "Connections"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "writing",                :unit => "Connections"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "waiting",                :unit => "Connections"}
  metric_group.save
  metric_group
end

def create_nginx_dashboard(metric_group, name, server_list)
  log "Creating new Nginx Dashboard"
  servers = server_list.map {|server_entry| server_entry["name"]}
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
  # Create a dashboard for only the servers we've defined:
  #CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => servers, :metrics => metrics)
end

####################################################################

# init - check apikey? make sure site is valid, and apikey is ok
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == "redis"
    return ensure_redis_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "mysql"
    return ensure_mysql_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "apache"
    return ensure_apache_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  elsif service == "nginx"
    return ensure_nginx_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == "redis"
    create_redis_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  elsif service == "mysql"
    create_mysql_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  elsif service == "apache"
    create_apache_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  elsif service == "nginx"
    create_nginx_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == "redis"
    monitor_redis(@config[service]["servers"], metric_group.name)
  elsif service == "mysql"
    monitor_mysql(@config[service]["servers"], metric_group.name)
  elsif service == "apache"
    monitor_apache(@config[service]["servers"], metric_group.name)
  elsif service == "nginx"
    monitor_nginx(@config[service]["servers"], metric_group.name)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

#################################

MAX_RETRIES = 30
last_failure = 0

MAX_SETUP_RETRIES = 5
setup_retries = MAX_SETUP_RETRIES


begin
  metric_groups = CopperEgg::MetricGroup.find
  dashboards = CopperEgg::CustomDashboard.find
rescue => e
  puts "Error connecting to server.  Retying (#{setup_retries}) more times..."
  log "#{e.inspect}"
  log e.backtrace[0..30].join("\n") if @debug
  raise e if @debug
  sleep 2
  setup_retries -= 1
  retry if setup_retries > 0
  raise e
end

@services.each do |service|
  if @config[service] && @config[service]["servers"].length > 0
    begin
      log "Checking for existence of metric group for #{service}"
      metric_group = metric_groups.detect {|m| m.name == @config[service]["group_name"]}
      metric_group = ensure_metric_group(metric_group, service)
      raise "Could not create a metric group for #{service}" if metric_group.nil?

      log "Checking for existence of #{service} Dashboard"
      dashboard = dashboards.detect {|d| d.name == @config[service]["dashboard"]} || create_dashboard(service, metric_group)
      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log e.message
      log "#{e.inspect}"
      log e.backtrace[0..30].join("\n") if @debug
      next
    end
    child_pid = fork {
      trap("INT") { child_interrupt if !@interrupted }
      trap("TERM") { child_interrupt if !@interrupted }

      last_failure = 0
      retries = MAX_RETRIES
      begin
        # reset retries counter if last failure was more than 10 minutes ago
        monitor_service(service, metric_group)
      rescue => e
        puts "Error monitoring #{service}.  Retying (#{retries}) more times..."
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        # updated 7-9-2013, removed the # before if @debug
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

# ... wait for all processes to exit ...
p Process.waitall
