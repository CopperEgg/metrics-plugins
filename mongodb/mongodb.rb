#!/usr/bin/env ruby
#
# CopperEgg mongodb monitoring    mongodb.rb
#

require 'rubygems'
require 'bundler/setup'
require 'getoptlong'
require 'copperegg'
require 'json/pure'
require 'yaml'
require 'mongo'

class CopperEggAgentError < Exception; end

####################################################################

def help
  puts 'usage: $0 args'
  puts 'Examples:'
  puts '  -c config.yml'
  puts '  -f 60                 (for 60s updates. Valid values: 5, 15, 60, 300, 900, 3600)'
  puts '  -k hcd7273hrejh712    (your APIKEY from the UI dashboard settings)'
  puts '  -a https://api.copperegg.com    (API endpoint to use [DEBUG ONLY])'
end

TIME_STRING = '%Y/%m/%d %H:%M:%S'.freeze
##########
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

if CopperEgg::Api.apikey.nil?
  log 'You need to supply an apikey with the -k option or in the config.yml.'
  exit
end

if @services.empty?
  log 'No services listed in the config file.'
  log 'Nothing will be monitored!'
  exit
end

@freq = 60 unless [5, 15, 60, 300, 900, 3600, 21_600].include?(@freq)
log "Update frequency set to #{@freq}s."

####################################################################

def connect_to_mongo(hostname, port, user, pw, db)
  if pw.nil?
    client = Mongo::Client.new(["#{hostname}:#{port}"], database: db)
  else
    client = Mongo::Client.new(["#{hostname}:#{port}"], user: user, password: pw, database: db)
  end
  client
rescue
  log "Unable to connect to Mongo at #{hostname}:#{port}"
  return nil
end

#########################################################################

def monitor_mongodb(mongo_servers, group_name)
  log 'Monitoring mongo databases: '
  return if @interrupted

  until @interrupted
    return if @interrupted

    mongo_servers.each do |mhost|
      return if @interrupted

      my_dbs = mhost['databases']
      my_dbs.each do |db|
        return if @interrupted
        mongo_client = connect_to_mongo(mhost['hostname'], mhost['port'],
                                        db['username'], db['password'], db['name'])
        mongo_db = mongo_client.database

        if mongo_db
          begin
            dbstats = mongo_db.command(dbstats: 1)
            dbstats = dbstats.first
          rescue
            log "Error getting mongo stats for database: #{mhost['database']} [skipping]"
            next
          end
          metrics = {}
          metrics['db_objects']            = dbstats['objects']
          metrics['db_indexes']            = dbstats['indexes']
          metrics['db_datasize']           = dbstats['dataSize']
          metrics['db_storage_size']       = dbstats['storageSize']
          metrics['db_index_size']         = dbstats['indexSize']
          begin
            server_stats = mongo_db.command(serverStatus: 1)
            server_stats = server_status.first
          rescue
            log "Error getting mongo server stats for database: #{mhost['database']} [skipping]"
            next
          end

          # Extract assert stats
          if server_stats.key? 'asserts'
            metrics['asserts_msg']              = server_stats['asserts']['msg']
            metrics['asserts_regular']          = server_stats['asserts']['regular']
            metrics['asserts_rollover']         = server_stats['asserts']['rollovers']
            metrics['asserts_user']             = server_stats['asserts']['user']
            metrics['asserts_warning']          = server_stats['asserts']['warning']
          end

          # Extract connections stats
          if server_stats.key? 'connections'
            metrics['connections_available']    = dbstats['connections']['available']
            metrics['connections_current']      = dbstats['connections']['current']
          end

          # Check for 'metrics' key
          if server_stats.key? 'metrics'

            # Extract cursor stats
            if server_stats['metrics'].key? 'cursor'
              metrics['cursors_timedout']         = dbstats['metrics']['cursor']['timedOut']
              metrics['cursors_total_open']       = dbstats['metrics']['cursor']['open']['total']
            end

            # Extract document stats
            if server_stats['metrics'].key? 'document'
              metrics['document_inserted']        = dbstats['metrics']['document']['inserted']
              metrics['document_deleted']         = dbstats['metrics']['document']['deleted']
              metrics['document_updated']         = dbstats['metrics']['document']['updated']
              metrics['document_returned']        = dbstats['metrics']['document']['returned']
            end

            # Extract getlastError stats
            if server_stats['metrics'].key? 'getLastError'
              metrics['get_last_error_write_timeouts']   = dbstats['metrics']['getLastError']['wtimeouts']
              metrics['get_last_error_write_concerns'] = dbstats['metrics']['getLastError']['wtime']['num']
            end

            # Extract operation stats
            if server_stats['metrics'].key? 'operation'
              metrics['op_fastmod']              = dbstats['metrics']['operation']['fastmod']
              metrics['op_idhack']               = dbstats['metrics']['operation']['idhack']
              metrics['op_scan_and_order']       = dbstats['metrics']['operation']['scanAndOrder']
            end

            # Extract queryExecutor stats
            if server_stats['metrics'].key? 'queryExecutor'
              metrics['index_item_scan_per_query'] = dbstats['metrics']['queryExecutor']['scanned']
            end

            # Extract record stats
            if server_stats['metrics'].key? 'record'
              metrics['records_moved']             = dbstats['metrics']['record']['moves']
            end

            # Check for 'repl' key
            if server_stats['metrics'].key? 'repl'

              # Extract for replication apply stats
              if server_stats['metrics']['repl'].key? 'apply'
                metrics['batch_applied_num']        = dbstats['metrics']['repl']['apply']['batches']['num']
                metrics['batch_time_spent']         = dbstats['metrics']['repl']['apply']['batches']['totalMillis']
              end

              # Extract replication buffer stats
              if server_stats['metrics']['repl'].key? 'buffer'
                metrics['oplog_operations']         = dbstats['metrics']['repl']['buffer']['count']
                metrics['oplog_buffer_size']        = dbstats['metrics']['repl']['buffer']['sizeBytes']
                metrics['max_buffer_size']          = dbstats['metrics']['repl']['buffer']['maxSizeBytes']
              end

              # Extract replication network stats
              if server_stats['metrics']['repl'].key? 'network'
                metrics['repl_sync_src_data_read']  = dbstats['metrics']['repl']['network']['bytes']
                metrics['getmores_op']              = dbstats['metrics']['repl']['network']['getmores']['num']
                metrics['getmores_op_fraction']     = dbstats['metrics']['repl']['network']['getmores']['totalMillis']
                metrics['op_read_from_repl_src']    = dbstats['metrics']['repl']['network']['ops']
                metrics['oplog_qry_proc_create_ps'] = dbstats['metrics']['repl']['network']['readersCreated']
              end
            end

            # Extract ttl stats
            if server_stats['metrics'].key? 'ttl'
              metrics['ttl_deletedDocuments']     = dbstats['metrics']['ttl']['deletedDocuments']
              metrics['ttl_passes']               = dbstats['metrics']['ttl']['passes']
            end

          end

          # Extract page_faults stats
          if server_stats.key? 'extra_info'
            metrics['page_faults']              = dbstats['extra_info']['page_faults']
          end

          # Extract global lock stats
          if server_stats.key? 'globalLock'
            metrics['global_lock_total_time']   = dbstats['globalLock']['totalTime']
            metrics['current_queue_lock']       = dbstats['globalLock']['currentQueue']['total']
            metrics['current_queue_read_lock']  = dbstats['globalLock']['currentQueue']['readers']
            metrics['current_queue_write_lock'] = dbstats['globalLock']['currentQueue']['writers']
          end

          # Extract memory stats
          if server_stats.key? 'mem'
            metrics['mem_mapped']               = dbstats['mem']['mapped']
            metrics['mem_resident']             = dbstats['mem']['resident']
            metrics['mem_virtual']              = dbstats['mem']['virtual']
          end

          # Extract opcounters
          if server_stats.key? 'opcounters'
            metrics['op_inserts']               = dbstats['opcounters']['insert']
            metrics['op_queries']               = dbstats['opcounters']['query']
            metrics['op_updates']               = dbstats['opcounters']['update']
            metrics['op_deletes']               = dbstats['opcounters']['delete']
            metrics['op_getmores']              = dbstats['opcounters']['getmore']
            metrics['op_commands']              = dbstats['opcounters']['command']
          end

          # Extract replication opcounters
          if server_stats.key? 'opcountersRepl'
            metrics['repl_inserts']             = dbstats['opcountersRepl']['insert']
            metrics['repl_queries']             = dbstats['opcountersRepl']['query']
            metrics['repl_updates']             = dbstats['opcountersRepl']['update']
            metrics['repl_deletes']             = dbstats['opcountersRepl']['delete']
            metrics['repl_getmores']            = dbstats['opcountersRepl']['getmore']
            metrics['repl_commands']            = dbstats['opcountersRepl']['command']
          end

          # Extract uptime
          metrics['uptime']                   = dbstats['uptime']
          mongo_client.close

        end
        # puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}"
        CopperEgg::MetricSample.save(group_name, "#{mhost['name']}_#{db['name']}", Time.now.to_i, metrics)
      end
    end
    interruptible_sleep @freq
  end
end

def ensure_mongodb_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating MongoDB metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label,
                                              frequency: @freq)
  else
    log 'Updating MongoDB metric group'
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << { type: 'ce_gauge', name: 'db_objects', unit: 'Objects' }
  metric_group.metrics << { type: 'ce_gauge', name: 'db_indexes', unit: 'Indexes' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_datasize', unit: 'Bytes' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_storage_size', unit: 'Bytes' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_index_size', unit: 'Bytes' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_regular', unit: 'assertion/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_warning', unit: 'assertion/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_msg', unit: 'assertion/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_user', unit: 'assertion/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_rollover', unit: 'assertion/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'connections_available', unit: 'connection' }
  metric_group.metrics << { type: 'ce_gauge', name: 'connections_current', unit: 'connection' }
  metric_group.metrics << { type: 'ce_gauge', name: 'page_faults', unit: 'fault/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_inserts', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_queries', unit: 'query/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_updates', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_deletes', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_getmores', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_commands', unit: 'command/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_inserts', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_queries', unit: 'query/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_updates', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_deletes', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_getmores', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_commands', unit: 'command/second' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'uptime', unit: 'second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'cursors_totalOpen', unit: 'cursors' }
  metric_group.metrics << { type: 'ce_gauge', name: 'cursors_timedOut', unit: 'cursors' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_inserted', unit: 'document/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_deleted', unit: 'document/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_updated', unit: 'document/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_returned', unit: 'document/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_fastmode', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_idhack', unit: 'query/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_scanAndOrder', unit: 'query/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'getLastError_wtimeouts', unit: 'event/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'getLastError_wrt_concern',
                            unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'ttl_deletedDocuments',
                            unit: 'document/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'ttl_passes', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'batch_applied_num', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'batch_time_spent', unit: 'millis/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'mem_resident', unit: 'megabyte' }
  metric_group.metrics << { type: 'ce_gauge', name: 'mem_virtual', unit: 'megabyte' }
  metric_group.metrics << { type: 'ce_gauge', name: 'mem_mapped', unit: 'megabyte' }
  metric_group.metrics << { type: 'ce_gauge', name: 'globalLock_totalTime', unit: 'microsecond' }
  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_lock', unit: 'operation' }
  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_read_lock', unit: 'operation' }
  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_write_lock', unit: 'operation' }
  metric_group.metrics << { type: 'ce_gauge', name: 'index_itm_scan_per_query',
                            unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'record_moved', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'max_buffer_size', unit: 'bytes' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_operations', unit: 'operation' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_buffer_size', unit: 'bytes' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_qry_proc_create_ps',
                            unit: 'process/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_sync_src_data_read',
                            unit: 'bytes/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_read_from_repl_src',
                            unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'getmores_op', unit: 'operation/second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'getmores_op_fraction',
                            unit: 'operation/second' }
  metric_group.save
  metric_group
end

def create_mongodb_dashboard(metric_group, name)
  log 'Creating new MongoDB Dashboard'
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics)
end

#########################################################################

def ensure_metric_group(metric_group, service)
  if service == 'mongodb'
    return ensure_mongodb_metric_group(metric_group, @config[service]['group_name'],
                                       @config[service]['group_label'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'mongodb'
    create_mongodb_dashboard(metric_group, @config[service]['dashboard'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'mongodb'
    monitor_mongodb(@config[service]['servers'], metric_group.name)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

##########################################################################

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
  next unless @config[service] && !@config[service]['servers'].empty?
  begin
    log "Checking for existence of metric group for #{service}"
    metric_group = metric_groups.detect { |m| m.name == @config[service]['group_name'] }
    metric_group = ensure_metric_group(metric_group, service)
    raise "Could not create a metric group for #{service}" if metric_group.nil?
    log "Checking for existence of #{@config[service]['dashboard']}"
    dashboard = dashboards.detect { |d| d.name == @config[service]['dashboard'] } ||
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
