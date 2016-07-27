#!/usr/bin/env ruby
#
# CopperEgg postgresql monitoring  postgresql.rb
#
#
# PostgreSQL queries are based on the PastgreSQL statistics gatherer,
# written by Mahlon E. Smith <mahlon@martini.nu>,

require 'rubygems'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'pg'

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

base_path = '/usr/local/copperegg/ucm-metrics/postgresql'
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

if CopperEgg::Api.apikey.nil?
  log "You need to supply an apikey with the -k option or in the config.yml."
  exit
end

if @services.empty?
  log "No services listed in the config file."
  log "Nothing will be monitored!"
  exit
end

@freq = 60 if ![5, 15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."


####################################################################

def connect_to_postgresql(hostname, port, user, pw, db, sslmode)

  begin
    @cxn = PG.connect(
      :dbname   => db,
      :host     => hostname,
      :port     => port,
      :user     => user,
      :password => pw,
      :sslmode  => sslmode
    )
    rescue Exception => e
        log "Error connecting to postgresql database #{db}, on #{hostname}:#{port}"
        return nil
    end
  return @cxn
end


def get_stats(pgcxn, dbname)
  res = pgcxn.exec %Q{
    SELECT
        MAX(stat_db.numbackends)              AS connections,
        MAX(stat_db.xact_commit)              AS commits,
        MAX(stat_db.xact_rollback)            AS rollbacks,
        MAX(stat_db.blks_read)                AS blksread,
        MAX(stat_db.blks_hit)                 AS blkshit,
        MAX(stat_db.tup_returned)             AS rowreturned,
        MAX(stat_db.tup_fetched)              AS rowfetched,
        MAX(stat_db.deadlocks)                  AS deadlocks,
        MAX(stat_db.temp_bytes)               AS tempbytes,
        MAX(stat_db.temp_files)               AS tempfiles,
        MAX(stat_bgwriter.checkpoints_timed)       AS ckhptscheduled,
        MAX(stat_bgwriter.checkpoints_req)         AS ckhptrequested,
        MAX(stat_bgwriter.buffers_checkpoint)      AS bufwrtnchkpt,
        MAX(stat_bgwriter.buffers_clean)           AS bufwrtnbgwriter,
        MAX(stat_bgwriter.buffers_backend)         AS bufwrtnbackend,
        MAX(stat_bgwriter.buffers_alloc)           AS bufallocated,
        MAX(stat_bgwriter.buffers_backend_fsync)   AS fsyncallexecuted,
        MAX(stat_bgwriter.checkpoint_write_time)   AS ckhwrttym,
        MAX(stat_bgwriter.checkpoint_sync_time)    AS ckhsynctym,
        MAX(stat_dbsize.dbsize)                    AS dbsize,
        MAX(stat_locks.locks)                      AS locks,
        SUM(stat_tables.n_tup_ins)            AS rowins,
        SUM(stat_tables.n_tup_upd)            AS rowupd,
        SUM(stat_tables.n_tup_del)            AS rowdel,
        SUM(stat_tables.seq_scan)             AS seqscan,
        SUM(stat_tables.seq_tup_read)         AS seqrowfetched,
        SUM(stat_tables.idx_scan)             AS idxscn,
        SUM(stat_tables.idx_tup_fetch)        AS idxrowfetched,
        SUM(stat_tables.n_tup_hot_upd)        AS rowhotupd,
        SUM(stat_tables.n_live_tup)           AS liverows,
        SUM(stat_tables.n_dead_tup)           AS deadrows,
        MAX(conn_details.setting)             AS max_conn,
        ((MAX(stat_db.numbackends)::decimal / MAX(conn_details.setting)::decimal) * 100)    AS percentconn,
        SUM(statio_tables.heap_blks_read)     AS heapblkrd,
        SUM(statio_tables.heap_blks_hit)      AS heapblkhit,
        SUM(statio_tables.idx_blks_read)      AS idxblkrd,
        SUM(statio_tables.idx_blks_hit)       AS idxblkhit,
        SUM(statio_tables.toast_blks_read)    AS tblkrd,
        SUM(statio_tables.toast_blks_hit)     AS tblkhit,
        SUM(statio_tables.tidx_blks_read)     AS tidxrd,
        SUM(statio_tables.tidx_blks_hit)      AS tidxhit,
        SUM(stat_indexes.idx_tup_read)        AS idxrowread
    FROM
        pg_stat_database    AS stat_db,
        pg_stat_all_tables AS stat_tables,
        pg_stat_bgwriter AS stat_bgwriter,
        (SELECT COUNT(*) AS locks FROM pg_locks ) AS stat_locks,
        (SELECT pg_database_size('%s') AS dbsize) AS stat_dbsize,
        (SELECT * FROM pg_settings WHERE  name = 'max_connections') AS conn_details,
        pg_statio_all_tables AS statio_tables,
        pg_stat_all_indexes AS stat_indexes
    WHERE
        stat_db.datname = '%s';
    } % [ dbname, dbname ]
  return res[0]

end


def monitor_postgresql(pg_servers, group_name)
  log "Monitoring postgresql: "
  return if @interrupted
  server_db_map = Hash.new
  pg_servers.each do |mhost|
    pg_dbs = mhost['databases']
    dbhash = Hash.new
    pg_dbs.each do |db|
      dbhash[ db['name'] ] = nil
    end
    server_db_map[ mhost['hostname']] = dbhash
  end
  while !@interupted do
    return if @interrupted

    pg_servers.each do |mhost|
      return if @interrupted

      thishash = server_db_map[mhost['hostname']]
      pg_dbs = mhost['databases']
      pg_dbs.each do |db|
        return if @interrupted
        pgcxn = thishash[db['name']]
        if pgcxn == nil
          pgcxn = connect_to_postgresql(mhost["hostname"], mhost["port"].to_i, db["username"], db["password"], db["name"], mhost["sslmode"])
          if pgcxn == nil
            log "[skipping]"
            next
          end
          thishash[db['name']] = pgcxn
        end
        begin
          curr_stats = get_stats(pgcxn, db['name'])
        rescue Exception => e
          log "Error getting postgresql stats from: #{mhost['hostname']}, #{db['name']} [skipping]"
          next
        end

        metrics = {}
        metrics['commits'] = curr_stats['commits'].to_i
        metrics['rollbacks'] = curr_stats['rollbacks'].to_i
        metrics['disk_reads'] = curr_stats['blksread'].to_i
        metrics['buffer_hits'] = curr_stats['blkshit'].to_i
        metrics['rows_returned'] = curr_stats['rowreturned'].to_i
        metrics['rows_fetched'] = curr_stats['rowfetched'].to_i

        metrics['rows_inserted'] = curr_stats['rowins'].to_i
        metrics['rows_updated'] = curr_stats['rowupd'].to_i
        metrics['rows_deleted'] = curr_stats['rowdel'].to_i
        metrics['sequential_scans'] = curr_stats['seqscan'].to_i
        metrics['live_rows_fetched_by_seqscan'] = curr_stats['seqrowfetched'].to_i
        metrics['index_scans'] = curr_stats['idxscn'].to_i
        metrics['live_rows_fetched_by_idxscan'] = curr_stats['idxrowfetched'].to_i
        metrics['rows_hot_updated'] = curr_stats['rowhotupd'].to_i
        metrics['live_rows'] = curr_stats['liverows'].to_i
        metrics['dead_rows'] = curr_stats['deadrows'].to_i

        metrics['deadlocks'] = curr_stats['deadlocks'].to_i
        metrics['temp_bytes'] = curr_stats['tempbytes'].to_i
        metrics['temp_files'] = curr_stats['tempfiles'].to_i

        metrics['checkpoints_scheduled'] = curr_stats['ckhptscheduled'].to_i
        metrics['checkpoints_requested'] = curr_stats['ckhptrequested'].to_i
        metrics['buf_written_in_checkpoints'] = curr_stats['bufwrtnchkpt'].to_i
        metrics['buf_written_by_bgwriter'] = curr_stats['bufwrtnbgwriter'].to_i
        metrics['buf_written_by_backend'] = curr_stats['bufwrtnbackend'].to_i
        metrics['buf_allocated'] = curr_stats['bufallocated'].to_i
        metrics['fsync_calls_executed'] = curr_stats['fsyncallexecuted'].to_i
        metrics['checkpoint_writing_time'] = curr_stats['ckhwrttym'].to_i
        metrics['checkpoint_sync_time'] = curr_stats['ckhsynctym'].to_i

        metrics['db_size'] = curr_stats['dbsize'].to_i

        metrics['locks'] = curr_stats['locks'].to_i

        metrics['connections'] = curr_stats['connections'].to_i
        metrics['max_connections'] = curr_stats['max_conn'].to_i
        metrics['percent_used_connections'] = curr_stats['percentconn'].to_i

        metrics['heap_blocks_read'] = curr_stats['heapblkrd'].to_i
        metrics['heap_blocks_hit'] = curr_stats['heapblkhit'].to_i
        metrics['index_blocks_read'] = curr_stats['idxblkrd'].to_i
        metrics['index_blocks_hit'] = curr_stats['idxblkhit'].to_i
        metrics['toast_block_read'] = curr_stats['tblkrd'].to_i
        metrics['toast_blocks_hit'] = curr_stats['tblkhit'].to_i
        metrics['toast_index_block_read'] = curr_stats['tidxrd'].to_i
        metrics['toast_index_block_hit'] = curr_stats['tidxhit'].to_i

        metrics['index_row_read'] = curr_stats['idxrowread'].to_i

        puts "#{group_name} - #{mhost['name']} - #{db['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
        rslt = CopperEgg::        MetricSample.save(group_name, "#{mhost['name']}_#{db['name']}", Time.now.to_i,         metrics)
      end
    end
    interruptible_sleep @freq
  end
end


def ensure_postgresql_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating postgresql metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating postgresql metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {type: 'ce_counter', name: 'commits', label: 'Commits', unit: 'commits'}
  metric_group.metrics << {type: 'ce_counter', name: 'rollbacks', label: 'Rollbacks', unit: 'rollbacks'}
  metric_group.metrics << {type: 'ce_counter', name: 'disk_reads', label: 'Disk Reads', unit: 'disk reads'}
  metric_group.metrics << {type: 'ce_counter', name: 'buffer_hits', label: 'Buffer Hits', unit: 'buffer hits'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_returned', label: 'Rows Returned', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_fetched', label: 'Rows Fetched', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_inserted', label: 'Rows Inserted', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_updated', label: 'Rows Updated', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_deleted', label: 'Rows Deleted', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'sequential_scans', label: 'Sequential Scans', unit: 'sequential scans'}
  metric_group.metrics << {type: 'ce_counter', name: 'live_rows_fetched_by_seqscan', label: 'Live Rows Fetched by Sequential Scans', unit: 'live rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'index_scans', label: 'Index Scans', unit: 'index scans'}
  metric_group.metrics << {type: 'ce_counter', name: 'live_rows_fetched_by_idxscan', label: 'Live Rows Fetched by Index Scans', unit: 'live rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'rows_hot_updated', label: 'Rows HOT Updated', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'live_rows', label: 'Live Rows', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'dead_rows', label: 'Dead Rows', unit: 'rows'}
  metric_group.metrics << {type: 'ce_counter', name: 'deadlocks', label: 'Deadlocks', unit: 'deadlocks'}
  metric_group.metrics << {type: 'ce_counter', name: 'temp_bytes', label: 'Temp Bytes', unit: 'bytes'}
  metric_group.metrics << {type: 'ce_counter', name: 'temp_files', label: 'Temp Files', unit: 'temporary files'}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoints_scheduled', label: 'Checkpoints Scheduled', unit: 'checkpoints'}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoints_requested', label: 'Checkpoints Requested', unit: 'checkpoints'}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_in_checkpoints', label: 'Buffers Written During Checkpoints', unit: 'buffers'}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_by_bgwriter', label: 'Buffers Written by Background Writer', unit: 'buffers'}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_by_backend', label: 'Buffers Written by Backend', unit: 'buffers'}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_allocated', label: 'Buffers Allocated', unit: 'buffers'}
  metric_group.metrics << {type: 'ce_counter', name: 'fsync_calls_executed', label: 'fsync Calls Executed', unit: 'fsync calls'}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoint_writing_time', label: 'Checkpoint Processing - Writing Time', unit: 'milliseconds'}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoint_sync_time', label: 'Checkpoint Processing - Synchronizing Time', unit: 'milliseconds'}
  metric_group.metrics << {type: 'ce_counter', name: 'db_size', label: 'Database Size', unit: 'bytes'}
  metric_group.metrics << {type: 'ce_counter', name: 'locks', label: 'Locks', unit: 'locks'}
  metric_group.metrics << {type: 'ce_counter', name: 'connections', label: 'Connections', unit: 'connections'}
  metric_group.metrics << {type: 'ce_counter', name: 'max_connections', label: 'Max Connections', unit: 'connections'}
  metric_group.metrics << {type: 'ce_gauge', name: 'percent_used_connections', label: 'Percentage Used Connections', unit: '% connections'}
  metric_group.metrics << {type: 'ce_counter', name: 'heap_blocks_read', label: 'Heap Blocks Read', unit: 'blocks'}
  metric_group.metrics << {type: 'ce_counter', name: 'heap_blocks_hit', label: 'Heap Blocks Hit', unit: 'buffer hits'}
  metric_group.metrics << {type: 'ce_counter', name: 'index_blocks_read', label: 'Index Blocks Read', unit: 'blocks'}
  metric_group.metrics << {type: 'ce_counter', name: 'index_blocks_hit', label: 'Index Blocks Hit', unit: 'buffer hits'}
  metric_group.metrics << {type: 'ce_counter', name: 'toast_block_read', label: 'Toast Block Read', unit: 'blocks'}
  metric_group.metrics << {type: 'ce_counter', name: 'toast_blocks_hit', label: 'Toast Blocks Hit', unit: 'bufer hits'}
  metric_group.metrics << {type: 'ce_counter', name: 'toast_index_block_read', label: 'Toast Index Blocks Read', unit: 'blocks'}
  metric_group.metrics << {type: 'ce_counter', name: 'toast_index_block_hit', label: 'Toast Index Blocks Hit', unit: 'buffer hits'}
  metric_group.metrics << {type: 'ce_counter', name: 'index_row_read', label: 'Index Row Read', unit: 'rows'}
  metric_group.save
  metric_group
end

def create_postgresql_dashboard(metric_group, name, server_list)
  log "Creating new PostgreSQL Dashboard"
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
end

####################################################################

# init - check apikey? make sure site is valid, and apikey is ok
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == 'postgresql'
    return ensure_postgresql_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'postgresql'
    create_postgresql_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'postgresql'
    monitor_postgresql(@config[service]["servers"], metric_group.name)
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
  if @config[service] && @config[service]["servers"].length > 0
    begin
      log "Checking for existence of metric group for #{service}"
      metric_group = metric_groups.detect {|m| m.name == @config[service]["group_name"]}
      metric_group = ensure_metric_group(metric_group, service)
      raise "Could not create a metric group for #{service}" if metric_group.nil?
      log "Checking for existence of #{@config[service]['dashboard']}"
      dashboard = dashboards.detect {|d| d.name == @config[service]["dashboard"]} || create_dashboard(service, metric_group)
      log "Could not create a dashboard for #{service}" if dashboard.nil?
    rescue => e
      log e.message
      next
    end

    child_pid = fork {
      trap("INT") { child_interrupt if !@interrupted }
      trap("TERM") { child_interrupt if !@interrupted }
      last_failure = 0
      retries = MAX_RETRIES
      begin
        monitor_service(service, metric_group)
      rescue => e
        log "Error monitoring #{service}.  Retrying (#{retries}) more times..."
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        # updated 7-9-2013, removed the # before if @debug
        raise e   if @debug
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

# ... wait for all processes to exit ...
p Process.waitall


