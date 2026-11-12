#!/run/current-system/sw/bin/vpsadmin-api-ruby
# frozen_string_literal: true

require_relative 'reconcile_owned_ip_charges_lib'

exit ReconcileOwnedIpCharges.run(ARGV)
