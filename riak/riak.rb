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

config_file = 'config.yml'
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

if @services.length == 0
  log 'No services listed in the config file.'
  log 'Nothing will be monitored!'
  exit
end

@freq = 60 if ![15, 60, 300, 900, 3600, 21600].include?(@freq)
log "Update frequency set to #{@freq}s."

####################################################################

def monitor_riak(riak_servers, group_name)
  log 'Monitoring riak: '
  return if @interrupted

  while !@interupted do
    return if @interrupted

    riak_servers.each do |rhost|
      return if @interrupted

      begin
        uri = URI.parse("#{rhost['url']}/stats")
        response = Net::HTTP.get_response(uri)
        if response.code != '200'
          return nil
        end

        # Parse json reply
        rstats = JSON.parse(response.body)

      rescue Exception => e
        log "Error getting riak stats from: #{rhost['url']} [skipping]"
        next
      end

      metrics = {}
      metrics['node_gets']                      = rstats['node_gets'].to_i
      metrics['node_puts']                      = rstats['node_puts'].to_i
      metrics['vnode_gets']                     = rstats['vnode_gets'].to_f
      metrics['vnode_puts']                     = rstats['vnode_puts'].to_i
      metrics['read_repairs']                   = rstats['read_repairs'].to_i
      metrics['read_repairs_total']             = rstats['read_repairs_total'].to_i
      metrics['coord_redirs_total']             = rstats['coord_redirs_total'].to_i
      metrics['node_get_fsm_objsize_mean']      = rstats['node_get_fsm_objsize_mean'].to_i
      metrics['node_get_fsm_objsize_median']    = rstats['node_get_fsm_objsize_median'].to_i
      metrics['node_get_fsm_objsize_95']        = rstats['node_get_fsm_objsize_95'].to_i
      metrics['node_get_fsm_objsize_100']       = rstats['node_get_fsm_objsize_100'].to_i
      metrics['node_get_fsm_time_mean']         = rstats['node_get_fsm_time_mean'].to_i
      metrics['node_get_fsm_time_median']       = rstats['node_get_fsm_time_median'].to_i
      metrics['node_get_fsm_time_95']           = rstats['node_get_fsm_time_95'].to_i
      metrics['node_get_fsm_time_100']          = rstats['node_get_fsm_time_100'].to_i
      metrics['node_put_fsm_time_mean']         = rstats['node_put_fsm_time_mean'].to_i
      metrics['node_put_fsm_time_median']       = rstats['node_put_fsm_time_median'].to_i
      metrics['node_put_fsm_time_95']           = rstats['node_put_fsm_time_95'].to_i
      metrics['node_put_fsm_time_100']          = rstats['node_put_fsm_time_100'].to_i
      metrics['node_get_fsm_siblings_mean']     = rstats['node_get_fsm_siblings_mean'].to_i
      metrics['node_get_fsm_siblings_median']   = rstats['node_get_fsm_siblings_median'].to_i
      metrics['node_get_fsm_siblings_95']       = rstats['node_get_fsm_siblings_95'].to_i
      metrics['node_get_fsm_siblings_100']      = rstats['node_get_fsm_siblings_100'].to_i
      metrics['memory_processes_used']          = rstats['memory_processes_used'].to_i
      metrics['sys_process_count']              = rstats['sys_process_count'].to_i
      metrics['pbc_connect']                    = rstats['pbc_connect'].to_i
      metrics['pbc_active']                     = rstats['pbc_active'].to_i
      metrics['ring_num_partitions']            = rstats['ring_num_partitions'].to_i
      metrics['riak_kv_vnodes_running']         = rstats['riak_kv_vnodes_running'].to_i
      metrics['riak_pipe_vnodes_running']       = rstats['riak_pipe_vnodes_running'].to_i
      metrics['precommit_fail']                 = rstats['precommit_fail'].to_i
      metrics['postcommit_fail']                = rstats['postcommit_fail'].to_i

      puts "#{group_name} - #{rhost['name']} - #{Time.now.to_i} - #{metrics.inspect}" if @verbose
      CopperEgg::MetricSample.save(group_name, rhost['name'], Time.now.to_i, metrics)
    end
    interruptible_sleep @freq
  end
end

def ensure_riak_metric_group(metric_group, group_name, group_label)
  if metric_group.nil? || !metric_group.is_a?(CopperEgg::MetricGroup)
    log 'Creating riak metric group'
    metric_group = CopperEgg::MetricGroup.new(:name => group_name, :label => group_label, :frequency => @freq)
  else
    log 'Updating riak metric group'
    metric_group.frequency = @freq
  end

  metric_group.metrics = []
  metric_group.metrics << {:type => 'ce_gauge', :name => 'node_gets',              			:unit => 'Node GETs'}
  metric_group.metrics << {:type => 'ce_gauge', :name => 'node_puts',                	    :unit => 'Node PUTs'}
  metric_group.metrics << {:type => 'ce_gauge', :name => 'vnode_gets',             			:unit => 'vnode GETs'}
  metric_group.metrics << {:type => 'ce_counter', :name => 'vnode_puts',				    :unit => 'vnode PUTs'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'read_repairs',					:unit => 'Node Read Repairs'}
  metric_group.metrics << {:type => 'ce_counter',   :name => 'read_repairs_total',			:unit => 'Total Node Read Repairs'}

  metric_group.metrics << {:type => 'ce_counter',   :name => 'coord_redirs_total',			:unit => 'Redirected Requests'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_objsize_mean',		:unit => 'Mean Object Size'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_objsize_median',	:unit => 'Median Object Size'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_objsize_95',		:unit => '95th %ile Object Size'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_objsize_100',		:unit => '100th %ile Object Size'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_time_mean',		:unit => 'Mean GET Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_time_median',		:unit => 'Median GET Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_time_95',			:unit => '95th %tile GET Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_time_100',			:unit => '100th %ile GET Latency (us)'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_put_fsm_time_mean',		:unit => 'Mean PUT Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_put_fsm_time_median',		:unit => 'Median PUT Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_put_fsm_time_95',			:unit => '95th %ile PUT Latency (us)'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_put_fsm_time_100',			:unit => '100th %ile PUT Latency (us)'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_siblings_mean',	:unit => 'Mean GET Siblings'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_siblings_median',	:unit => 'Median GET Siblings'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_siblings_95',		:unit => '95th %ile GET Siblings'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'node_get_fsm_siblings_100',		:unit => '100th %ile GET Siblings'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'memory_processes_used',			:unit => 'Total memory used'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'sys_process_count',				:unit => 'Number of processes'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'pbc_connect',					:unit => 'Protocol Buffer Connections'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'pbc_active',					:unit => 'Active Protocol Buffer Connections'}

  metric_group.metrics << {:type => 'ce_gauge',   :name => 'ring_num_partitions',           :unit => 'Partitions in the ring'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'riak_kv_vnodes_running',        :unit => 'Running vnodes'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'riak_pipe_vnodes_running',      :unit => 'Running pipe vnodes'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'precommit_fail',                :unit => 'Precommit fails'}
  metric_group.metrics << {:type => 'ce_gauge',   :name => 'postcommit_fail',               :unit => 'Postcommit fails'}

  metric_group.save
  metric_group
end

def create_riak_dashboard(metric_group, name, server_list)
  log 'Creating new riak Dashboard'
  servers = server_list.map {|server_entry| server_entry['name']}
  metrics = metric_group.metrics.map {|metric| metric['name']}
  # Create a dashboard for all identifiers:
  CopperEgg::CustomDashboard.create(metric_group, :name => name, :identifiers => nil, :metrics => metrics)
end

# init - check apikey? make sure site is valid, and apikey is ok
trap('INT') { parent_interrupt }
trap('TERM') { parent_interrupt }

#################################

def ensure_metric_group(metric_group, service)
  if service == 'riak'
    return ensure_riak_metric_group(metric_group, @config[service]['group_name'], @config[service]['group_label'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def create_dashboard(service, metric_group)
  if service == 'riak'
    create_riak_dashboard(metric_group, @config[service]['dashboard'], @config[service]['servers'])
  else
    raise CopperEggAgentError.new("Service #{service} not recognized")
  end
end

def monitor_service(service, metric_group)
  if service == 'riak'
    monitor_riak(@config[service]['servers'], metric_group.name)
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

      log "Checking for existence of #{service} Dashboard"
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
