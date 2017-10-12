require 'rubygems'
require 'pg'

(0..3).each do |index|
  abort('error') if ARGV[index].nil? || ARGV[index].to_s.empty?
end

begin
  connection = PG.connect(host: ARGV[0],
    port:     ARGV[1],
    dbname:   ARGV[2],
    sslmode:  ARGV[3],
    user:     ARGV[4],
    password: ARGV[5])
  connection.exec %Q{ SELECT MAX(numbackends) FROM pg_stat_database where datname = '%s'}% [ARGV[2]][0]
  connection.close
  puts 'success'
rescue StandardError => e
  puts('error')
end
