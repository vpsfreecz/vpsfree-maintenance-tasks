#!/usr/bin/env ruby
require 'highline/import'
require 'haveapi/client'

API_URL = 'https://api.vpsfree.cz'
# API_URL = 'http://localhost:4567'

SERVERS = {
  # 'dns1.dev.vpsfree.cz' => {
  #   node: 200,
  #   ipv4: '172.16.106.65',
  #   ipv6: nil,
  #   user_zones: false
  # },
  # 'dns2.dev.vpsfree.cz' => {
  #   node: 201,
  #   ipv4: '172.16.106.66',
  #   ipv6: nil,
  #   user_zones: true
  # },

  'ns1.vpsfree.cz' => {
    node: 11,
    ipv4: '37.205.9.232',
    ipv6: '2a03:3b40:fe:3fd::1',
    user_zones: false
  },
  'ns2.vpsfree.cz' => {
    node: 12,
    ipv4: '37.205.11.51',
    ipv6: '2a03:3b40:101:ca::1',
    user_zones: false
  },
  'ns3.vpsfree.cz' => {
    node: 13,
    ipv4: '37.205.15.45',
    ipv6: '2a03:3b40:fe:2be::1',
    user_zones: true
  },
  'ns4.vpsfree.cz' => {
    node: 14,
    ipv4: '37.205.11.85',
    ipv6: '2a03:3b40:101:4::1',
    user_zones: true
  },
}

ZONES = {
  '8.205.37.in-addr.arpa.' => '37.205.8.0/24',
  '9.205.37.in-addr.arpa.' => '37.205.9.0/24',
  '10.205.37.in-addr.arpa.' => '37.205.10.0/24',
  '11.205.37.in-addr.arpa.' => '37.205.11.0/24',
  '12.205.37.in-addr.arpa.' => '37.205.12.0/24',
  '13.205.37.in-addr.arpa.' => '37.205.13.0/24',
  '14.205.37.in-addr.arpa.' => '37.205.14.0/24',
  '15.205.37.in-addr.arpa.' => '37.205.15.0/24',
  '164.8.185.in-addr.arpa.' => '185.8.164.0/24',
  '165.8.185.in-addr.arpa.' => '185.8.165.0/24',
  '166.8.185.in-addr.arpa.' => '185.8.166.0/24',
  '0.0.1.0.0.4.b.3.3.0.a.2.ip6.arpa.' => '2a03:3b40:100::/48',
  '0.4.b.3.3.0.a.2.ip6.arpa.' => '2a03:3b40::/32'
}

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

def create_servers(api)
  SERVERS.to_h do |name, opts|
    puts "Creating server #{name}"

    s = api.dns_server.create({
      node: opts[:node],
      name:,
      ipv4_addr: opts[:ipv4],
      ipv6_addr: opts[:ipv6],
      enable_user_dns_zones: opts[:user_zones]
    })

    [name, s]
  end
end

def create_zones(api, servers)
  ZONES.each do |name, network|
    puts "Creating zone #{name}"

    address, prefix = network.split('/')

    zone = api.dns_zone.create({
      name:,
      reverse_network_address: address,
      reverse_network_prefix: prefix.to_i,
      role: 'reverse_role',
      default_ttl: 3600,
      email: 'hostmaster@vpsfree.cz'
    })

    servers.each_value do |s|
      next if s.enable_user_dns_zones

      puts "  adding to server #{s.name}"

      api.dns_server_zone.create(
        dns_server: s.id,
        dns_zone: zone.id
      )
    end
  end
end

api = authenticate

servers = create_servers(api)
create_zones(api, servers)
