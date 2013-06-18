#!/usr/bin/env ruby
#
# CopperEgg postgresql monitoring  postgres.rb
#
# Copyright 2013 CopperEgg Corporation.  All rights reserved.
#
# License:: MIT License
#
# PostgreSQL queries are based on the PastgreSQL statistics gatherer,
# written by Mahlon E. Smith <mahlon@martini.nu>,
#
# Based on queries by Kenny Gorman.
#     http://www.kennygorman.com/wordpress/?page_id=491

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

config_file = "config.yml"
@apihost = nil
@debug = false
@verbose = false
@freq = 60  # update frequency in seconds
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

if @services.length == 0
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
  rescue CopperEggAgentError.new("Unable to connect to postgresql at #{hostname}:#{port}")
    return nil
  end
  return @cxn
end


def get_stats(pgcxn, dbname)
  res = pgcxn.exec %Q{
    SELECT
        MAX(stat_db.xact_commit)       AS commits,
        MAX(stat_db.xact_rollback)     AS rollbacks,
        MAX(stat_db.blks_read)         AS blksread,
        MAX(stat_db.blks_hit)          AS blkshit,
        MAX(stat_db.numbackends)       AS backends,
        SUM(stat_tables.seq_scan)      AS seqscan,
        SUM(stat_tables.seq_tup_read)  AS seqtprd,
        SUM(stat_tables.idx_scan)      AS idxscn,
        SUM(stat_tables.idx_tup_fetch) AS idxtrd,
        SUM(stat_tables.n_tup_ins)     AS ins,
        SUM(stat_tables.n_tup_upd)     AS upd,
        SUM(stat_tables.n_tup_del)     AS del,
        MAX(stat_locks.locks)          AS locks
    FROM
        pg_stat_database    AS stat_db,
        pg_stat_all_tables AS stat_tables,
        (SELECT COUNT(*) AS locks FROM pg_locks ) AS stat_locks
    WHERE
				stat_db.datname = '%s';
    } % [ dbname ]
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
            log "Error connecting to #{mhost['hostname']}, #{db['name']} [skipping]"
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
        metrics['commits']       = curr_stats['commits'].to_i
        metrics['rollbacks']     = curr_stats['rollbacks'].to_i
        metrics['blksread']      = curr_stats['blksread'].to_i
        metrics['blkshit']       = curr_stats['blkshit'].to_i
        metrics['backends']        = curr_stats['backends'].to_i
        metrics['seqscan']       = curr_stats['seqscan'].to_i
        metrics['seqtprd']       = curr_stats['seqtprd'].to_i
        metrics['idxscn']        = curr_stats['idxscn'].to_i
        metrics['idxtrd']        = curr_stats['idxtrd'].to_i
        metrics['ins']           = curr_stats['ins'].to_i
        metrics['upd']           = curr_stats['upd'].to_i
        metrics['del']           = curr_stats['del'].to_i
        metrics['locks']         = curr_stats['locks'].to_i

        puts "#{group_name} - #{mhost['name']} - #{db['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
        rslt = CopperEgg::MetricSample.save(group_name, db['name'], Time.now.to_i, metrics)
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
  metric_group.metrics << {:type => "ce_counter", :name => "commits",                   :unit => "commits per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "rollbacks",                 :unit => "rollbacks per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "blksread",                  :unit => "blocks read per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "blkshit",                   :unit => "cache hit blocks per sec"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "backends",                  :unit => "backends"}
  metric_group.metrics << {:type => "ce_counter", :name => "seqscan",                   :unit => "seq scans per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "seqtprd",                   :unit => "seq rows read per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "idxscn",                    :unit => "index scans per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "idxtrd",                    :unit => "index rows fetched per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "ins",                       :unit => "row inserts per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "upd",                       :unit => "row updates per sec"}
  metric_group.metrics << {:type => "ce_counter", :name => "del",                       :unit => "row deletes per sec"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "locks",                     :unit => "locks"}
  metric_group.save
  metric_group
end

def create_postgresql_dashboard(metric_group, name, server_list)
  log "Creating new PostgreSQL Dashboard"
  #servers = server_list.map {|server_entry| server_entry["name"]}
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
begin
  # reset retries counter if last failure was more than 10 minutes ago
  retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
  dashboards = CopperEgg::CustomDashboard.find
  metric_groups = CopperEgg::MetricGroup.find
rescue => e
  log "Error connecting to server.  Retying (#{retries}) more times..."
  raise e if @debug
  sleep 2
  retries -= 1
  last_failure = Time.now.to_i
  retry if retries > 0
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
      begin
        # reset retries counter if last failure was more than 10 minutes ago
        retries = MAX_RETRIES if Time.now.to_i - last_failure > 600
        monitor_service(service, metric_group)
      rescue => e
        log "Error monitoring #{service}.  Retying (#{retries}) more times..."
        raise e   #if @debug
        sleep 2
        retries -= 1
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


