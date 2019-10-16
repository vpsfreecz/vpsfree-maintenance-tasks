#!/run/nodectl/nodectl script
require 'nodectld/standalone'

Dataset = Struct.new(:name, :used, :actual) do
  def leaked
    used - actual
  end
end

datasets = []

File.open('usage_stats.txt') do |f|
  f.each_line do |line|
    ds, used, actual = line.split
    datasets << Dataset.new(ds, used.to_i, actual.to_i)
  end
end

puts sprintf('%-30s %11s %11s  %11s', 'DATASET', 'USED', 'ACTUAL', 'LEAKED')
datasets.sort do |a, b|
  a.leaked <=> b.leaked
end.reverse_each do |ds|
  puts sprintf(
    '%-30s %10.2fM %10.2fM  %10.2fM',
    ds.name,
    ds.used / 1024.0 / 1024,
    ds.actual / 1024.0 / 1024,
    ds.leaked / 1024.0 / 1024,
  )
end
