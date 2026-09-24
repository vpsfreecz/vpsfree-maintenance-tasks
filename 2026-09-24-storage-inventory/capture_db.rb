#!/run/current-system/sw/bin/vpsadmin-api-ruby
require_relative 'db_capture'

StorageInventory::DbCapture.cli(ARGV)
