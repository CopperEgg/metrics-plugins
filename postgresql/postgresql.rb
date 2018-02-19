#!/usr/bin/env ruby
#
# CopperEgg postgresql monitoring  postgresql.rb
#
#
# PostgreSQL queries are based on the PastgreSQL statistics gatherer,
# written by Mahlon E. Smith <mahlon@martini.nu>,

base_path = '/usr/local/copperegg/ucm-metrics/postgresql'
ENV['BUNDLE_GEMFILE'] = "#{base_path}/Gemfile"

##################################################

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'pg'

class CopperEggAgentError < Exception; end

####################################################################

def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60                 (for 60s updates. Valid values: 15, 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])'
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
  if !@config['copperegg'].nil?
    CopperEgg::Api.apikey = @config['copperegg']['apikey'] if !@config['copperegg']['apikey'].nil? && CopperEgg::Api.apikey.nil?
    CopperEgg::Api.host = @config['copperegg']['host'] if !@config['copperegg']['host'].nil?
    @freq = @config['copperegg']['frequency'] if !@config['copperegg']['frequency'].nil?
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

@freq = 60 if ![15, 60, 300, 900, 3600, 21600].include?(@freq)
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
  res = (pgcxn.exec %Q{
    SELECT
        MAX(stat_db.numbackends)              AS connections,
        MAX(stat_db.xact_commit)              AS commits,
        MAX(stat_db.xact_rollback)            AS rollbacks,
        MAX(stat_db.blks_read)                AS blksread,
        MAX(stat_db.blks_hit)                 AS blkshit,
        MAX(stat_db.tup_returned)             AS rowreturned,
        MAX(stat_db.tup_fetched)              AS rowfetched,
        MAX(stat_db.deadlocks)                AS deadlocks,
        MAX(stat_db.temp_bytes)               AS tempbytes,
        MAX(stat_db.temp_files)               AS tempfiles,
        ((MAX(stat_db.numbackends)::decimal / MAX(conn_details.setting)::decimal) * 100)    AS percentconn
    FROM
        pg_stat_database    AS stat_db,
        (SELECT * FROM pg_settings WHERE  name = 'max_connections') AS conn_details
    WHERE
        stat_db.datname = '%s';
    } % [ dbname ])[0]

  res.merge!((pgcxn.exec %q{
    SELECT
        MAX(stat_bgwriter.checkpoints_timed)       AS ckhptscheduled,
        MAX(stat_bgwriter.checkpoints_req)         AS ckhptrequested,
        MAX(stat_bgwriter.buffers_checkpoint)      AS bufwrtnchkpt,
        MAX(stat_bgwriter.buffers_clean)           AS bufwrtnbgwriter,
        MAX(stat_bgwriter.buffers_backend)         AS bufwrtnbackend,
        MAX(stat_bgwriter.buffers_alloc)           AS bufallocated,
        MAX(stat_bgwriter.buffers_backend_fsync)   AS fsyncallexecuted,
        MAX(stat_bgwriter.checkpoint_write_time)   AS ckhwrttym,
        MAX(stat_bgwriter.checkpoint_sync_time)    AS ckhsynctym
    FROM
        pg_stat_bgwriter AS stat_bgwriter;
    })[0])

  res.merge!((pgcxn.exec %q{
    SELECT
        SUM(stat_indexes.idx_tup_read)        AS idxrowread
    FROM
        pg_stat_all_indexes AS stat_indexes;
    })[0])

  res.merge!((pgcxn.exec %Q{
    SELECT
        MAX(stat_dbsize.dbsize)               AS dbsize
    FROM
       (SELECT pg_database_size('%s') AS dbsize) AS stat_dbsize;
    } % [ dbname ])[0])


  res.merge!((pgcxn.exec %q{
    SELECT
        MAX(stat_locks.locks)                     AS locks
    FROM
        (SELECT COUNT(*) AS locks FROM pg_locks ) AS stat_locks;
    })[0])


  res.merge!((pgcxn.exec %Q{
    SELECT
        MAX(conn_details.setting)             AS max_conn
    FROM
        (SELECT * FROM pg_settings WHERE  name = 'max_connections') AS conn_details;
    })[0])


  res.merge!((pgcxn.exec %q{
    SELECT
        SUM(statio_tables.heap_blks_read)     AS heapblkrd,
        SUM(statio_tables.heap_blks_hit)      AS heapblkhit,
        SUM(statio_tables.idx_blks_read)      AS idxblkrd,
        SUM(statio_tables.idx_blks_hit)       AS idxblkhit,
        SUM(statio_tables.toast_blks_read)    AS tblkrd,
        SUM(statio_tables.toast_blks_hit)     AS tblkhit,
        SUM(statio_tables.tidx_blks_read)     AS tidxrd,
        SUM(statio_tables.tidx_blks_hit)      AS tidxhit
    FROM
        pg_statio_all_tables AS statio_tables;
    })[0])

  res.merge!((pgcxn.exec %q{
    SELECT
        SUM(stat_tables.n_tup_ins)            AS rowins,
        SUM(stat_tables.n_tup_upd)            AS rowupd,
        SUM(stat_tables.n_tup_del)            AS rowdel,
        SUM(stat_tables.seq_scan)             AS seqscan,
        SUM(stat_tables.seq_tup_read)         AS seqrowfetched,
        SUM(stat_tables.idx_scan)             AS idxscn,
        SUM(stat_tables.idx_tup_fetch)        AS idxrowfetched,
        SUM(stat_tables.n_tup_hot_upd)        AS rowhotupd,
        SUM(stat_tables.n_live_tup)           AS liverows,
        SUM(stat_tables.n_dead_tup)           AS deadrows
    FROM
        pg_stat_all_tables AS stat_tables;
    })[0])

  res
end


def monitor_postgresql(pg_servers, group_name)
  log 'Monitoring postgresql: '
  return if @interrupted
  while !@interupted do
    return if @interrupted

    pg_servers.each do |mhost|
      return if @interrupted

      pg_dbs = mhost['databases']
      pg_dbs.each do |db|
        return if @interrupted

        pgcxn = connect_to_postgresql(mhost['hostname'], mhost['port'].to_i, db['username'], db['password'], db['name'], mhost['sslmode'])
        if pgcxn == nil
          log '[skipping]'
          next
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


def ensure_postgresql_metric_group(metric_group, group_name, group_label, service)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating postgresql metric group'
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label,
      :frequency => @freq, service: service)
  else
    log 'Updating postgresql metric group'
    metric_group.service = service
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {type: 'ce_gauge', name: 'commits', label: 'Commits', unit: 'transaction/second', position: 0}
  metric_group.metrics << {type: 'ce_gauge', name: 'rollbacks', label: 'Rollbacks', unit: 'transaction/second', position: 1}
  metric_group.metrics << {type: 'ce_gauge', name: 'disk_reads', label: 'Disk Reads', unit: 'block/second', position: 2}
  metric_group.metrics << {type: 'ce_gauge', name: 'buffer_hits', label: 'Buffer Hits', unit: 'hit/second', position: 3}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_returned', label: 'Rows Returned', unit: 'row/second', position: 4}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_fetched', label: 'Rows Fetched', unit: 'row/second', position: 5}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_inserted', label: 'Rows Inserted', unit: 'row/second', position: 6}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_updated', label: 'Rows Updated', unit: 'row/second', position: 7}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_deleted', label: 'Rows Deleted', unit: 'row/second', position: 8}
  metric_group.metrics << {type: 'ce_gauge', name: 'sequential_scans', label: 'Sequential Scans', unit: 'sequential scans', position: 9}
  metric_group.metrics << {type: 'ce_gauge', name: 'live_rows_fetched_by_seqscan', label: 'Live Rows Fetched by Sequential Scans', unit: 'row/second', position: 10}
  metric_group.metrics << {type: 'ce_gauge', name: 'index_scans', label: 'Index Scans', unit: 'index scans', position: 11}
  metric_group.metrics << {type: 'ce_gauge', name: 'live_rows_fetched_by_idxscan', label: 'Live Rows Fetched by Index Scans', unit: 'row/second', position: 12}
  metric_group.metrics << {type: 'ce_gauge', name: 'rows_hot_updated', label: 'Rows HOT Updated', unit: 'row/second', position: 13}
  metric_group.metrics << {type: 'ce_gauge', name: 'live_rows', label: 'Live Rows', unit: 'rows', position: 14}
  metric_group.metrics << {type: 'ce_gauge', name: 'dead_rows', label: 'Dead Rows', unit: 'rows', position: 15}
  metric_group.metrics << {type: 'ce_gauge', name: 'deadlocks', label: 'Deadlocks', unit: 'deadlocks', position: 16}
  metric_group.metrics << {type: 'ce_gauge', name: 'temp_bytes', label: 'Temp Bytes', unit: 'bps', position: 17}
  metric_group.metrics << {type: 'ce_gauge', name: 'temp_files', label: 'Temp Files', unit: 'file/second', position: 18}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoints_scheduled', label: 'Checkpoints Scheduled', unit: 'checkpoints', position: 19}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoints_requested', label: 'Checkpoints Requested', unit: 'checkpoints', position: 20}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_in_checkpoints', label: 'Buffers Written During Checkpoints', unit: 'buffers', position: 21}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_by_bgwriter', label: 'Buffers Written by Background Writer', unit: 'buffers', position: 22}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_written_by_backend', label: 'Buffers Written by Backend', unit: 'buffers', position: 23}
  metric_group.metrics << {type: 'ce_counter', name: 'buf_allocated', label: 'Buffers Allocated', unit: 'buffers', position: 24}
  metric_group.metrics << {type: 'ce_counter', name: 'fsync_calls_executed', label: 'fsync Calls Executed', unit: 'fsync calls', position: 25}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoint_writing_time', label: 'Checkpoint Processing - Writing Time', unit: 'ms', position: 26}
  metric_group.metrics << {type: 'ce_counter', name: 'checkpoint_sync_time', label: 'Checkpoint Processing - Synchronizing Time', unit: 'ms', position: 27}
  metric_group.metrics << {type: 'ce_gauge', name: 'db_size', label: 'Database Size', unit: 'b', position: 28}
  metric_group.metrics << {type: 'ce_gauge', name: 'locks', label: 'Locks', unit: 'locks', position: 29}
  metric_group.metrics << {type: 'ce_gauge', name: 'connections', label: 'Connections', unit: 'connections', position: 30}
  metric_group.metrics << {type: 'ce_gauge', name: 'max_connections', label: 'Max Connections', unit: 'connections', position: 31}
  metric_group.metrics << {type: 'ce_gauge', name: 'percent_used_connections', label: 'Percentage Used Connections', unit: '% connections', position: 32}
  metric_group.metrics << {type: 'ce_gauge', name: 'heap_blocks_read', label: 'Heap Blocks Read', unit: 'block/second', position: 33}
  metric_group.metrics << {type: 'ce_gauge', name: 'heap_blocks_hit', label: 'Heap Blocks Hit', unit: 'hit/second', position: 34}
  metric_group.metrics << {type: 'ce_gauge', name: 'index_blocks_read', label: 'Index Blocks Read', unit: 'block/second', position: 35}
  metric_group.metrics << {type: 'ce_gauge', name: 'index_blocks_hit', label: 'Index Blocks Hit', unit: 'hit/second', position: 36}
  metric_group.metrics << {type: 'ce_gauge', name: 'toast_block_read', label: 'Toast Block Read', unit: 'block/second', position: 37}
  metric_group.metrics << {type: 'ce_gauge', name: 'toast_blocks_hit', label: 'Toast Blocks Hit', unit: 'hit/second', position: 38}
  metric_group.metrics << {type: 'ce_gauge', name: 'toast_index_block_read', label: 'Toast Index Blocks Read', unit: 'block/second', position: 39}
  metric_group.metrics << {type: 'ce_gauge', name: 'toast_index_block_hit', label: 'Toast Index Blocks Hit', unit: 'hit/second', position: 40}
  metric_group.metrics << {type: 'ce_gauge', name: 'index_row_read', label: 'Index Row Read', unit: 'row/second', position: 41}
  metric_group.save
  metric_group
end

def create_postgresql_dashboard(metric_group, name)
  log 'Creating new PostgreSQL Dashboard'
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics,
                                    is_database: true, service: 'postgresql')
end

####################################################################

# init - check apikey? make sure site is valid, and apikey is ok
trap('INT') { parent_interrupt }
trap('TERM') { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == 'postgresql'
    return ensure_postgresql_metric_group(metric_group, @config[service]['group_name'],
      @config[service]['group_label'], service)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'postgresql'
    create_postgresql_dashboard(metric_group, @config[service]['dashboard'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'postgresql'
    monitor_postgresql(@config[service]['servers'], metric_group.name)
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
  if @config[service] && @config[service]['servers'].length > 0
    begin
      log "Checking for existence of metric group for #{service}"
      metric_group = metric_groups.detect {|m| m.name == @config[service]['group_name']}
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

    child_pid = fork {
      trap('INT') { child_interrupt if !@interrupted }
      trap('TERM') { child_interrupt if !@interrupted }
      last_failure = 0
      last_retry = Time.now.to_i
      retries = 0
      begin
        monitor_service(service, metric_group)
      rescue => e
        log "#{e.inspect}"
        log e.backtrace[0..30].join("\n") if @debug
        # updated 7-9-2013, removed the # before if @debug
        raise e   if @debug
        # reset retries counter if last retry is more than frequency of 5 successful tries
        retries = 0 if Time.now.to_i - last_retry > @freq * 5
        if retries < 30
          sleep_time = 2
        elsif retries < 60
          sleep_time = 60
        else
          sleep_time = 3600
        end
        retries += 1
        log "Error monitoring #{service}.  Retrying after (#{sleep_time}) seconds..."
        sleep sleep_time
        last_retry = Time.now.to_i
      retry
      end
    }
    @worker_pids.push child_pid
  end
end

# ... wait for all processes to exit ...
p Process.waitall


