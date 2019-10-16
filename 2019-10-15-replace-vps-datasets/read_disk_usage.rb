#!/run/nodectl/nodectl script
require 'nodectld/standalone'
  
class ThreadPool
  def initialize(threads = nil)
    @threads = threads || Etc.nprocessors
    @threads = 1 if @threads < 1
    @queue = Queue.new
  end

  def add(&block)
    queue << block
  end

  def run
    (1..threads).map do
      Thread.new { work }
    end.each(&:join)
  end

  protected
  attr_reader :threads, :queue

  def work
    loop do
      begin
        block = queue.pop(true)
      rescue ThreadError
        return
      end

      block.call
    end
  end
end

class Operation
  include OsCtl::Lib::Utils::Log
  include NodeCtld::Utils::System

  def initialize
    @mutex = Mutex.new
    @tp = ThreadPool.new(2)
  end

  def run
    datasets = []

    zfs(
      :list,
      '-Hrp -o name,usedbydataset,mountpoint -s avail',
      'tank/ct'
    ).output.split("\n").each do |line|
      name, used, mountpoint = line.split
      next if name == 'tank/ct' || name.start_with?('tank/ct/vpsadmin')

      datasets << {
        name: name,
        used: used.to_i,
        mountpoint: mountpoint,
      }
    end

    datasets.each do |ds|
      tp.add do
        puts "Checking dataset #{ds[:name]}"
        dir = File.join(ds[:mountpoint], 'private')
        next unless Dir.exist?(dir)

        t1 = Time.now
        actual = syscmd("du -s #{dir}").output.strip.to_i * 1024
        t2 = Time.now
        puts "#{ds[:name]}: checked in #{t2 - t1} secs"
        puts "#{ds[:name]}: diff in MB: #{((ds[:used] - actual) / 1024.0 / 1024).round(2)}"
        record(ds, actual)
      end
    end

    tp.run
  end

  protected
  attr_reader :mutex, :tp

  def record(ds, actual)
    mutex.synchronize do
      File.open('usage_stats.txt', 'a') do |f|
        f.puts("#{ds[:name]} #{ds[:used]} #{actual}")
      end
    end
  end
end

op = Operation.new
op.run
