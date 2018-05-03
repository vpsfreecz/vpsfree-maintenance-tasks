#!/usr/bin/env ruby
# Create a new environment and configure it. Read the file and edit
# configured values.
#
# Usage: edit and run ./create_environment.rb
#

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

ActiveRecord::Base.transaction do
  # Create the environment
  env = Environment.create!(
    label: 'Development',
    domain: 'vpsfree.cz',
    can_create_vps: true,
    can_destroy_vps: true,
    vps_lifetime: 30 * 24 * 60* 60,
    max_vps_count: 5,
    user_ip_ownership: true,
  )

  # Create environment config for every active user
  ::User.where('object_state < 2').each do |user|
    ::EnvironmentUserConfig.create!(
      environment: env,
      user: user,
      can_create_vps: true,
      can_destroy_vps: true,
      vps_lifetime: 30 * 24 * 60* 60,
      max_vps_count: 5,
      default: true, # set to false when some parameters from env are modified
    )
  end

  # Things you may also want to do:
  #
  #   - assign VPS configs to the environment, that's needed only for environments
  #     with OpenVZ nodes
  #
  #   - configure environment dataset plans, if you wish to have some available

  # Assign cluster resources to users
  assign = {
    memory: 4096,
    swap: 0,
    cpu: 8,
    diskspace: 120 * 1024,
    ipv4: 1,
    ipv6: 2**64,
    ipv4_private: 2**(32-27),
  }

  resources = ::ClusterResource.all.to_a

  ::User.where('object_state < 2').each do |user|
    resources.each do |r|
      ::UserClusterResource.create!(
        user: user,
        environment: env,
        cluster_resource: r,
        value: assign[ r.name.to_sym ],
      )
    end
  end

  fail 'comment this line'
end
