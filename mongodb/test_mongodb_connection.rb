require 'rubygems'
require 'mongo'

(0..5).each do |index|
  abort('error') if ARGV[index].nil? || ARGV[index].to_s.empty?
end

begin
  if ARG[4].nil? || ARGV[4] == ''
    client = Mongo::Client.new(["#{ARGV[0]}:#{ARGV[1]}"], database: ARGV[2])
  else
    client = Mongo::Client.new(["#{ARGV[0]}:#{ARGV[1]}"], database: ARGV[2], user: ARGV[3], password: ARGV[4])
  end
  if ARGV[5] == 'initial'
    client.command(serverStatus: 1)[0]
  else
    client.database.command(dbstats: 1)[0]
  end

  client.close
  puts('success')
rescue
  puts('error')
end
