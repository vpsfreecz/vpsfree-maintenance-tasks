ActiveRecord::Base.logger = nil

NETWORKS = [
  '77.93.223.0/24',
  '83.167.228.0/25',
  '2a01:430:17::/48',
  # '192.168.10.0/24',
  # '192.168.12.0/24',
]

module ReplaceIspIps
  def get_networks
    networks = NETWORKS.map do |v|
      addr, prefix = v.split('/')

      ::Network.find_by!(address: addr, prefix: prefix.to_i)
    end
  end

  def get_users_ips(networks)
    users_ips = {}

    networks.each do |net|
      net.ip_addresses.each do |ip|
        next if ip.current_owner.nil?

        # The IP is owned, but not assigned
        if ip.user_id && ip.network_interface_id.nil?
          warn "IP #{ip} not assigned, should be disowned first"
          next
        end

        user = ip.current_owner

        users_ips[user] ||= []
        users_ips[user] << ip
      end
    end

    users_ips
  end

  def execute_changes?
    ARGV.include?('EXECUTE=yes')
  end
end

IpReplacement = Struct.new(:vps, :netif, :src_ip, :dst_ip, keyword_init: true) do
  def to_json(*options)
    {
      vps: vps.id,
      netif: netif.id,
      src_ip: {
        id: src_ip.id,
        addr: src_ip.ip_addr,
      },
      dst_ip: {
        id: dst_ip.id,
        addr: dst_ip.ip_addr,
      },
    }.to_json(*options)
  end
end
