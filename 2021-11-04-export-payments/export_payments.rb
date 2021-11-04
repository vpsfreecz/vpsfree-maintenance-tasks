#!/run/current-system/sw/bin/vpsadmin-api-ruby
# Export all payments that took place in selected years, or affected memberships
# in those years.
#
# Usage: $0 <year...>
#

require 'vpsadmin'
require 'csv'
require 'time'

if ARGV.length < 1
  warn "Usage: #{$0} <year...>"
  exit(false)
end

# Necessary to load plugins
VpsAdmin::API.default

years = ARGV.map(&:to_i)
csv = CSV.new(
  STDOUT,
  col_sep: ';',
  headers: %w(payment_id user_id amount currency from_date to_date accounted_at),
  write_headers: true,
)

::UserPayment.includes(:incoming_payment).where(
  "YEAR(#{UserPayment.table_name}.created_at) IN (?) "+
  "OR YEAR(#{UserPayment.table_name}.from_date) IN (?) "+
  "OR YEAR(#{UserPayment.table_name}.to_date) IN (?)",
  years, years, years
).order("#{UserPayment.table_name}.created_at").each do |payment|
  if payment.incoming_payment
    amount = payment.incoming_payment.amount
    currency = payment.incoming_payment.currency
  else
    amount = payment.amount
    currency = 'CZK'
  end

  csv << [
    payment.id,
    payment.user_id,
    amount,
    currency,
    payment.from_date.iso8601,
    payment.to_date.iso8601,
    payment.created_at.iso8601,
  ]
end
