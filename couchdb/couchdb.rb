#!/usr/bin/env ruby
#
# Copyright 2013 IDERA.  All rights reserved.
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
@status_codes = ["200", "201", "202", "301", "304", "400", "401", "403", "404", "405", "409", "412", "500"]
@http_methods = ["COPY", "DELETE", "GET", "HEAD", "POST", "PUT"]

log "Update frequency set to #{@freq}s."

####################################################################

def monitor_couchdb(couchdb_servers, group_name)
  log "Monitoring CouchDB: "
  return if @interrupted

  while !@interupted do
    return if @interrupted

    couchdb_servers.each do |rhost|
      return if @interrupted

      begin
        uri = URI.parse("#{rhost['url']}/_stats?range=60")

        if !rhost['user'].empty? and !rhost['password'].empty?
            request = Net::HTTP::Get.new(uri.request_uri)
            request.basic_auth(rhost['user'], rhost['password'])
            response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        else
            response = Net::HTTP.get_response(uri)
        end

        if response.code != "200"
          return nil
        end

        # Parse json reply
        rstats = JSON.parse(response.body)

      rescue Exception => e
        log "Error getting CouchDB stats from: #{rhost['url']} [skipping]"
        next
      end

      metrics = {}

      #Database Metrics
      metrics["auth_cache_hits"]    = rstats["couchdb"]["auth_cache_hits"]["current"].to_i
      metrics["auth_cache_misses"]  = rstats["couchdb"]["auth_cache_misses"]["current"].to_i
      metrics["db_reads"]           = rstats["couchdb"]["database_reads"]["current"].to_i
      metrics["db_writes"]          = rstats["couchdb"]["database_writes"]["current"].to_i
      metrics["open_databases"]     = rstats["couchdb"]["open_databases"]["current"].to_i
      metrics["open_files"]         = rstats["couchdb"]["open_os_files"]["current"].to_i
      metrics["request_time"]       = rstats["couchdb"]["request_time"]["current"].to_f

      #httpd Metrics
      metrics["bulk_requests"]         = rstats["httpd"]["bulk_requests"]["current"].to_i
      metrics["requests"]              = rstats["httpd"]["requests"]["current"].to_i
      metrics["temporary_view_reads"]  = rstats["httpd"]["temporary_view_reads"]["current"].to_i
      metrics["view_reads"]            = rstats["httpd"]["view_reads"]["current"].to_i
      metrics["clients_requesting_changes"] = rstats["httpd"]["clients_requesting_changes"]["current"].to_i

      #httpd_request_methods Metrics
      @http_methods.each do |method|
        metrics[method] = rstats["httpd_request_methods"][method]["current"].to_i
      end

      #httpd_status_codes Metrics
      @status_codes.each do |status_code|
        metrics[status_code] = rstats["httpd_status_codes"][status_code]["current"].to_i
      end

      puts "#{group_name} - #{rhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, rhost["name"], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_couchdb_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log "Creating CouchDB metric group"
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log "Updating CouchDB metric group"
    metric_group.frequency = @freq
  end

  metric_group.metrics = []

  #Database Metrics
  metric_group.metrics << {:type => "ce_gauge",   :name => "auth_cache_hits",   :label => "Authentication Cache Hits",     :unit => "Hits"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "auth_cache_misses", :label => "Authentication Cache Misses",   :unit => "Misses"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "db_reads",          :label => "Database Reads",                      :unit => "Reads"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "db_writes",         :label => "Database Writes",                     :unit => "Writes"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "open_databases",    :label => "Open Databases",                :unit => "Databases"}
  metric_group.metrics << {:type => "ce_gauge",   :name => "open_files",        :label => "Open File Descriptors",         :unit => "Files"}
  metric_group.metrics << {:type => "ce_gauge_f", :name => "request_time",      :label => "Request Time",                  :unit => "Milliseconds"}

  #httpd Metrics
  metric_group.metrics << {:type => "ce_gauge", :name => "bulk_requests",              :label => "Bulk Requests",              :unit => "Requests"}
  metric_group.metrics << {:type => "ce_gauge", :name => "requests",                   :label => "Total HTTP Requests",        :unit => "Requests"}
  metric_group.metrics << {:type => "ce_gauge", :name => "temporary_view_reads",       :label => "Temporary View Reads",       :unit => "Reads"}
  metric_group.metrics << {:type => "ce_gauge", :name => "view_reads",                 :label => "View Reads",                 :unit => "Reads"}
  metric_group.metrics << {:type => "ce_gauge", :name => "clients_requesting_changes", :label => "Clients Requesting Changes", :unit => "Clients"}

  #httpd_request_methods Metrics
  @http_methods.each do |method|
    metric_group.metrics << {:type => "ce_gauge", :name => method, :label => "HTTP #{method} Responses", :unit => "Responses"}
  end

  #httpd_status_codes Metrics
  @status_codes.each do |status_code|
    metric_group.metrics << {:type => "ce_gauge", :name => status_code, :label => "HTTP #{status_code} Requests", :unit => "Requests"}
  end

  metric_group.save
  metric_group
end

def create_couchdb_dashboard(metric_group, name, server_list)
  log "Creating new CouchDB Dashboard"
  servers = server_list.map {|server_entry| server_entry["name"]}
  metrics = metric_group.metrics.map { |metric| metric["name"] }
  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
end

# init - check apikey? make sure site is valid, and apikey is ok
trap("INT") { parent_interrupt }
trap("TERM") { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == "couchdb"
    return ensure_couchdb_metric_group(metric_group, @config[service]["group_name"], @config[service]["group_label"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == "couchdb"
    create_couchdb_dashboard(metric_group, @config[service]["dashboard"], @config[service]["servers"])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == "couchdb"
    monitor_couchdb(@config[service]["servers"], metric_group.name)
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
  log "Error connecting to server.  Retrying (#{retries}) more times..."
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

      log "Checking for existence of #{service} Dashboard"
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
        puts "Error monitoring #{service}.  Retrying (#{retries}) more times..."
        log "#{e.inspect}"
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
    }
    @worker_pids.push child_pid
  end
end

# ... wait for all processes to exit ...
p Process.waitall
