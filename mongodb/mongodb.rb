#!/usr/bin/env ruby
#
# CopperEgg mongodb monitoring    mongodb.rb
#

base_path = '/usr/local/copperegg/ucm-metrics/mongodb'
ENV['BUNDLE_GEMFILE'] = "#{base_path}/Gemfile"

##################################################

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
  puts '  -f 60                 (for 60s updates. Valid values: 15, 60, 300, 900, 3600)'
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

def connect_to_mongo(hostname, port, user, pw, db)
  if pw.nil? || pw === ''
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
            db_stats = mongo_db.command(dbstats: 1)
            db_stats = db_stats.first
          rescue
            log "Error getting mongo stats for database: #{mhost['database']} [skipping]"
            next
          end
          metrics = {}
          metrics['db_objects']            = db_stats['objects']
          metrics['db_indexes']            = db_stats['indexes']
          metrics['db_datasize']           = db_stats['dataSize']
          metrics['db_storage_size']       = db_stats['storageSize']
          metrics['db_index_size']         = db_stats['indexSize']
        end
        mongo_client.close
        puts "#{group_name} - #{mhost['name']}_#{db['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
        result = CopperEgg::MetricSample.save(group_name, "#{mhost['name']}_#{db['name']}", Time.now.to_i, metrics)
        log "MetricSample save response - #{result}" if @verbose
      end
    end
    interruptible_sleep @freq
  end
end

def monitor_mongo_dbadmin(mongo_servers, group_name)
  log 'Monitoring mongo admin: '
  return if @interrupted

  while !@interupted do
    return if @interrupted

    mongo_servers.each do |mhost|
      return if @interrupted

      mongo_admin = connect_to_mongo(mhost['hostname'], mhost['port'], mhost['username'], mhost['password'], mhost['database'])

      if mongo_admin

        begin
          server_stats = mongo_admin.command(serverStatus: 1)
          server_stats = server_stats.first
        rescue
          log "Error getting mongo server stats for database: #{mhost['database']} [skipping]"
          next
        end

        metrics = {}
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
          metrics['connections_available']    = server_stats['connections']['available']
          metrics['connections_current']      = server_stats['connections']['current']
        end

        # Check for 'metrics' key
        if server_stats.key? 'metrics'

          # Extract cursor stats
          if server_stats['metrics'].key? 'cursor'
            metrics['cursors_timedout']         = server_stats['metrics']['cursor']['timedOut']
            metrics['cursors_total_open']       = server_stats['metrics']['cursor']['open']['total']
          end

          # Extract document stats
          if server_stats['metrics'].key? 'document'
            metrics['document_inserted']        = server_stats['metrics']['document']['inserted']
            metrics['document_deleted']         = server_stats['metrics']['document']['deleted']
            metrics['document_updated']         = server_stats['metrics']['document']['updated']
            metrics['document_returned']        = server_stats['metrics']['document']['returned']
          end

          # Extract getlastError stats
          if server_stats['metrics'].key? 'getLastError'
            metrics['get_last_error_write_timeouts']   = server_stats['metrics']['getLastError']['wtimeouts']
            metrics['get_last_error_write_concerns'] = server_stats['metrics']['getLastError']['wtime']['num']
          end

          # Extract operation stats
          if server_stats['metrics'].key? 'operation'
            metrics['op_fastmod']              = server_stats['metrics']['operation']['fastmod']
            metrics['op_idhack']               = server_stats['metrics']['operation']['idhack']
            metrics['op_scan_and_order']       = server_stats['metrics']['operation']['scanAndOrder']
          end

          # Extract queryExecutor stats
          if server_stats['metrics'].key? 'queryExecutor'
            metrics['index_item_scan_per_query'] = server_stats['metrics']['queryExecutor']['scanned']
          end

          # Extract record stats
          if server_stats['metrics'].key? 'record'
            metrics['records_moved']             = server_stats['metrics']['record']['moves']
          end

          # Check for 'repl' key
          if server_stats['metrics'].key? 'repl'

            # Extract for replication apply stats
            if server_stats['metrics']['repl'].key? 'apply'
              metrics['batch_applied_num']        = server_stats['metrics']['repl']['apply']['batches']['num']
              metrics['batch_time_spent']         = server_stats['metrics']['repl']['apply']['batches']['totalMillis']
            end

            # Extract replication buffer stats
            if server_stats['metrics']['repl'].key? 'buffer'
              metrics['oplog_operations']         = server_stats['metrics']['repl']['buffer']['count']
              metrics['oplog_buffer_size']        = server_stats['metrics']['repl']['buffer']['sizeBytes']
              metrics['max_buffer_size']          = server_stats['metrics']['repl']['buffer']['maxSizeBytes']
            end

            # Extract replication network stats
            if server_stats['metrics']['repl'].key? 'network'
              metrics['repl_sync_src_data_read']  = server_stats['metrics']['repl']['network']['bytes']
              metrics['getmores_op']              = server_stats['metrics']['repl']['network']['getmores']['num']
              metrics['op_read_from_repl_src']    = server_stats['metrics']['repl']['network']['ops']
              metrics['oplog_qry_proc_create_ps'] = server_stats['metrics']['repl']['network']['readersCreated']
            end
          end

          # Extract ttl stats
          if server_stats['metrics'].key? 'ttl'
            metrics['ttl_deleted_documents']     = server_stats['metrics']['ttl']['deletedDocuments']
            metrics['ttl_passes']               = server_stats['metrics']['ttl']['passes']
          end

        end

        # Extract page_faults stats
        if server_stats.key? 'extra_info'
          metrics['page_faults']              = server_stats['extra_info']['page_faults']
        end

        # Extract global lock stats
        if server_stats.key? 'globalLock'
          metrics['global_lock_total_time']   = server_stats['globalLock']['totalTime']
          metrics['current_queue_lock']       = server_stats['globalLock']['currentQueue']['total']
          metrics['current_queue_read_lock']  = server_stats['globalLock']['currentQueue']['readers']
          metrics['current_queue_write_lock'] = server_stats['globalLock']['currentQueue']['writers']
        end

        # Extract memory stats
        if server_stats.key? 'mem'
          metrics['mem_mapped']               = server_stats['mem']['mapped']
          metrics['mem_resident']             = server_stats['mem']['resident']
          metrics['mem_virtual']              = server_stats['mem']['virtual']
        end

        # Extract opcounters
        if server_stats.key? 'opcounters'
          metrics['op_inserts']               = server_stats['opcounters']['insert']
          metrics['op_queries']               = server_stats['opcounters']['query']
          metrics['op_updates']               = server_stats['opcounters']['update']
          metrics['op_deletes']               = server_stats['opcounters']['delete']
          metrics['op_getmores']              = server_stats['opcounters']['getmore']
          metrics['op_commands']              = server_stats['opcounters']['command']
        end

        # Extract replication opcounters
        if server_stats.key? 'opcountersRepl'
          metrics['repl_inserts']             = server_stats['opcountersRepl']['insert']
          metrics['repl_queries']             = server_stats['opcountersRepl']['query']
          metrics['repl_updates']             = server_stats['opcountersRepl']['update']
          metrics['repl_deletes']             = server_stats['opcountersRepl']['delete']
          metrics['repl_getmores']            = server_stats['opcountersRepl']['getmore']
          metrics['repl_commands']            = server_stats['opcountersRepl']['command']
        end

        # Extract uptime
        metrics['uptime']                   = server_stats['uptime']

      end

      mongo_admin.close

      puts "#{group_name} - #{mhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      result = CopperEgg::MetricSample.save(group_name, mhost['name'], Time.now.to_i, metrics)
      log "MetricSample save response - #{result}" if @verbose
    end
    interruptible_sleep @freq
  end
end

def ensure_mongodb_metric_group(metric_group, group_name, group_label, service)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating MongoDB metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label,
      frequency: @freq, service: service)
  else
    log 'Updating MongoDB metric group'
    metric_group.service = service
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << { type: 'ce_gauge', name: 'db_objects', unit: 'Objects', label: 'DB Objects' }
  metric_group.metrics << { type: 'ce_gauge', name: 'db_indexes', unit: 'Indexes', label: 'DB Index' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_datasize', unit: 'b', label: 'DB Data Size' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_storage_size', unit: 'b', label: 'DB Storage Size' }
  metric_group.metrics << { type: 'ce_gauge_f', name: 'db_index_size', unit: 'b', label: 'DB Index Size' }

  metric_group.save
  metric_group
end

def ensure_mongo_dbadmin_metric_group(metric_group, group_name, group_label, service)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating MongoDB Admin metric group'
    metric_group = CopperEgg::MetricGroup.new(name: group_name, label: group_label,
      frequency: @freq, service: service)
  else
    log 'Updating MongoDB Admin metric group'
    metric_group.service = service
    metric_group.frequency = @freq
  end

  metric_group.metrics = []

  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_regular', unit: 'Asserts', label: 'Regular Asserts Raised' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_warning', unit: 'Warnings', label: 'Warning Asserts' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_msg', unit: 'Asserts', label: 'Assert Messages' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_user', unit: 'Asserts', label: 'User Asserts' }
  metric_group.metrics << { type: 'ce_gauge', name: 'asserts_rollover', unit: 'Rollovers', label: 'Asserts Rollover' }

  metric_group.metrics << { type: 'ce_gauge', name: 'connections_available', unit: 'Connections', label: 'Connections Available' }
  metric_group.metrics << { type: 'ce_gauge', name: 'connections_current', unit: 'Connections', label: 'Current Connections' }

  metric_group.metrics << { type: 'ce_gauge', name: 'page_faults', unit: 'Faults', label: 'Page Faults' }

  metric_group.metrics << { type: 'ce_gauge', name: 'op_inserts', unit: 'Operations', label: 'Insert Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_queries', unit: 'Queries', label: 'Queries' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_updates', unit: 'Operations', label: 'Update Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_deletes', unit: 'Operations', label: 'Delete Operations'  }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_getmores', unit: 'Operations', label: 'Getmore Operations'  }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_commands', unit: 'Commands', label: 'Commands'  }

  metric_group.metrics << { type: 'ce_gauge', name: 'repl_inserts', unit: 'Operations', label: 'Replicated Insert Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_queries', unit: 'Queries', label: 'Replicated Queries' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_updates', unit: 'Operations', label: 'Replicated Update Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_deletes', unit: 'Operations', label: 'Replicated Delete Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_getmores', unit: 'Operations', label: 'Replicated Getmore Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'repl_commands', unit: 'Commands', label: 'Replicated Commands' }

  metric_group.metrics << { type: 'ce_counter', name: 'uptime', unit: 'Seconds', label: 'Uptime' }

  metric_group.metrics << { type: 'ce_gauge', name: 'cursors_total_open', unit: 'Cursors', label: 'Open Cursors' }
  metric_group.metrics << { type: 'ce_gauge', name: 'cursors_timedout', unit: 'Cursors', label: 'Timed Out Cursors' }

  metric_group.metrics << { type: 'ce_gauge', name: 'document_inserted', unit: 'Documents', label: 'Documents Inserted' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_deleted', unit: 'Documents', label: 'Documents Deleted' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_updated', unit: 'Documents', label: 'Documents Updated' }
  metric_group.metrics << { type: 'ce_gauge', name: 'document_returned', unit: 'Documents', label: 'Documents Returned' }

  metric_group.metrics << { type: 'ce_gauge', name: 'op_fastmod', unit: 'Operations', label: 'Fastmode Update Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_idhack', unit: 'Queries', label: 'Id Hack Queries' }

  metric_group.metrics << { type: 'ce_gauge', name: 'op_scan_and_order', unit: 'Queries', label: 'Scan and Order Queries' }

  metric_group.metrics << { type: 'ce_gauge', name: 'get_last_error_write_timeouts', unit: 'Operations', label: 'getLastError Write Timeouts' }
  metric_group.metrics << { type: 'ce_gauge', name: 'get_last_error_write_concerns', unit: 'Concerns', label: 'getLastError Write Concerns' }

  metric_group.metrics << { type: 'ce_gauge', name: 'ttl_deleted_documents', unit: 'Documents', label: 'Documents Deleted from Collections with a ttl index per second' }
  metric_group.metrics << { type: 'ce_gauge', name: 'ttl_passes', unit: 'Operations', label: 'ttl Indexes Passes' }

  metric_group.metrics << { type: 'ce_gauge', name: 'batch_applied_num', unit: 'Batches', label: 'Batches Applied Number' }
  metric_group.metrics << { type: 'ce_gauge', name: 'batch_time_spent', unit: 'Milliseconds', label: 'Time Spent on applying operations from Oplog' }

  metric_group.metrics << { type: 'ce_gauge', name: 'mem_resident', unit: 'mb', label: 'Resident Memory' }
  metric_group.metrics << { type: 'ce_gauge', name: 'mem_virtual', unit: 'mb', label: 'Virtual Memory' }
  metric_group.metrics << { type: 'ce_gauge', name: 'mem_mapped', unit: 'mb', label: 'Mapped Memory' }

  metric_group.metrics << { type: 'ce_gauge', name: 'global_lock_total_time', unit: 'Microseconds', label: 'Global Lock Total Time' }

  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_lock', unit: 'Operations', label: 'Current Lock Queue' }
  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_read_lock', unit: 'Operations', label: 'Current Read Lock Queue' }
  metric_group.metrics << { type: 'ce_gauge', name: 'current_queue_write_lock', unit: 'Operations', label: 'Current Write Lock Queue' }

  metric_group.metrics << { type: 'ce_gauge', name: 'index_item_scan_per_query', unit: 'Items', label: 'Index Items Scanned During Query' }
  metric_group.metrics << { type: 'ce_gauge', name: 'records_moved', unit: 'Records', label: 'Records Moved' }

  metric_group.metrics << { type: 'ce_gauge', name: 'max_buffer_size', unit: 'b', label: 'Max Buffer Size' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_operations', unit: 'Operations', label: 'Oplog Operations' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_buffer_size', unit: 'b', label: 'Oplog Buffer Size' }
  metric_group.metrics << { type: 'ce_gauge', name: 'oplog_qry_proc_create_ps', unit: 'Queries', label: 'Oplog Queries Processes' }

  metric_group.metrics << { type: 'ce_gauge', name: 'repl_sync_src_data_read', unit: 'b', label: 'Replication Sync Source Data Read' }
  metric_group.metrics << { type: 'ce_gauge', name: 'op_read_from_repl_src', unit: 'Operations', label: 'Operations Reads from Replication Source' }

  metric_group.metrics << { type: 'ce_gauge', name: 'getmores_op', unit: 'Operations', label: 'getMore Operations' }

  metric_group.save
  metric_group
end

def create_mongodb_dashboard(metric_group, name, service)
  log 'Creating new MongoDB Dashboard'
  metrics = metric_group.metrics || []

  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, name: name, identifiers: nil, metrics: metrics,
                                    is_database: true, service: service)
end

#########################################################################

def ensure_metric_group(metric_group, service)
  if service == 'mongodb'
    return ensure_mongodb_metric_group(metric_group, @config[service]['group_name'],
                                       @config[service]['group_label'], service)
  elsif service == 'mongodb_admin'
    return ensure_mongo_dbadmin_metric_group(metric_group, @config[service]['group_name'],
      @config[service]['group_label'], service)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'mongodb' || service == 'mongodb_admin'
    create_mongodb_dashboard(metric_group, @config[service]['dashboard'], service)
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'mongodb'
    monitor_mongodb @config[service]['servers'], metric_group.name
  elsif service == 'mongodb_admin'
    monitor_mongo_dbadmin @config[service]['servers'], metric_group.name
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

##########################################################################
### Main Code Starts from here
##########################################################################

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

@freq = 60 unless [15, 60, 300, 900, 3600, 21_600].include?(@freq)
log "Update frequency set to #{@freq}s."

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
    metric_group = metric_group.nil? ? nil :  metric_groups.detect { |m| m.name == @config[service]['group_name'] }
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
