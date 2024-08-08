#!/usr/bin/env ruby
#
# Reverse zones will have primary server on ns1.vpsfree.cz and ns2.vpsfree.cz
# will be converted to secondary. While the multi-master setup works, it doesn't
# give us anything, converting to secondary will save us transactions when
# setting reverse records.
#
require 'highline/import'
require 'haveapi/client'

API_URL = 'https://api.vpsfree.cz'
# API_URL = 'http://localhost:4567'

SERVER_NAME = 'ns2.vpsfree.cz'
# SERVER_NAME = 'dns2.dev.vpsfree.cz'

def authenticate
  api = HaveAPI::Client.new(API_URL)
  user, password = get_credentials

  api.authenticate(:token, user:, password:, lifetime: 'fixed', interval: 900) do |_action, params|
    ret = {}

    params.each do |name, desc|
      ret[name] = read_auth_param(name, desc)
    end

    ret
  end

  api
end

def get_credentials
  user = ask('Username: ') { |q| q.default = nil }.to_s

  password = ask('Password: ') do |q|
    q.default = nil
    q.echo = false
  end.to_s

  [user, password]
end

def read_auth_param(name, p)
  prompt = "#{p[:label] || name}: "

  ask(prompt) do |q|
    q.default = nil
    q.echo = !p[:protected]
  end
end

api = authenticate

server = api.dns_server.list.detect { |s| s.name == SERVER_NAME }
raise "Unable to find server #{SERVER_NAME}" if server.nil?

zones = api.dns_zone.list(
  source: 'internal_source',
  role: 'reverse_role',
  user: nil
)

zones.each do |zone|
  puts "Zone #{zone.name}"

  server_zone = api.dns_server_zone.list(dns_zone: zone.id).detect do |dsz|
    dsz.dns_server_id == server.id
  end

  if server_zone.nil?
    puts "  not found on #{server.name}"
    next
  end

  if server_zone.type == 'secondary_type'
    puts '  is already secondary type'
    next
  end

  STDOUT.write('Convert to secondary? [y\N]: ')
  STDOUT.flush
  next if STDIN.readline.strip.downcase != 'y'

  puts "  removing from #{server.name} as #{server_zone.type}"
  server_zone.delete

  puts "  adding to #{server.name} as secondary_type"
  api.dns_server_zone.create(
    dns_server: server.id,
    dns_zone: zone.id,
    type: 'secondary_type'
  )
end
