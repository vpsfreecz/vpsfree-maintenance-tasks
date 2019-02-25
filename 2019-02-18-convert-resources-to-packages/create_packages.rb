#!/usr/bin/env ruby
# Create a standard set of resource packages
#
# Usage:
#   $0

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

def run
  create(
    'Standard Production',
    memory: 4096,
    cpu: 8,
    diskspace: 120*1024,
    ipv4: 1,
    ipv4_private: 0,
    ipv6: 32,
  )
  create(
    'Standard Playground',
    memory: 4096,
    cpu: 8,
    diskspace: 120*1024,
    ipv4: 2,
    ipv4_private: 0,
    ipv6: 32,
  )
  create(
    'Standard Staging',
    memory: 4096,
    cpu: 8,
    diskspace: 120*1024,
    ipv4: 4,
    ipv4_private: 0,
    ipv6: 32 * (2**64),
  )
  create(
    'Standard NAS',
    diskspace: 250*1024,
  )
  create(
    'Membership Expansion',
    memory: 4096,
    cpu: 8,
    diskspace: 120*1024,
  )
  create(
    'Extra Public IPv4 Address',
    ipv4: 1,
  )
  (27..32).reverse_each do |prefix|
    cnt = 2 ** (32 - prefix)
    create(
      "Private IPv4 /#{prefix} (#{cnt} addresses)",
      ipv4_private: cnt,
    )
  end
end

def create(label, resources)
  ActiveRecord::Base.transaction do
    pkg = ::ClusterResourcePackage.create!(label: label)

    resources.each do |k, v|
      cr = ::ClusterResource.find_by!(name: k.to_s)

      ::ClusterResourcePackageItem.create!(
        cluster_resource_package: pkg,
        cluster_resource: cr,
        value: v,
      )
    end
  end
end

run
