#!/usr/bin/env ruby
# Export payments for year transitions, e.g. payments that were accepted
# in year X, but which prolong the membership to year X+1.
#
# Usage: $0 <base-year>
# Example:
#   $0 2018
#   Cover payments accepted in the year 2018 and also cover memberships fees
#   in the year 2019, e.g. Dec 2018 - Feb 2019.
#
Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'
require 'csv'
require 'time'

# Necessary to load plugins
VpsAdmin::API.default

if ARGV.count != 1
  warn "Usage: #{$0} <base-year>"
  exit(false)
end

year = ARGV[0].to_i

csv = CSV.new(
  STDOUT,
  col_sep: ';',
  headers: %w(user_id amount currency from_date to_date accounted_at),
  write_headers: true,
)

::UserPayment.includes(:incoming_payment).where(
  "YEAR(#{UserPayment.table_name}.created_at) = ?", year
).where(
  "YEAR(#{UserPayment.table_name}.from_date) = ?", year
).where(
  "YEAR(#{UserPayment.table_name}.to_date) = ?", year+1
).order("#{UserPayment.table_name}.user_id").each do |payment|
  if payment.incoming_payment
    amount = payment.incoming_payment.amount
    currency = payment.incoming_payment.currency
  else
    amount = payment.amount
    currency = 'CZK'
  end

  csv << [
    payment.user_id,
    amount,
    currency,
    payment.from_date.iso8601,
    payment.to_date.iso8601,
    payment.created_at.iso8601,
  ]
end
