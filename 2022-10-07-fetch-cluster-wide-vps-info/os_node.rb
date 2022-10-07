require 'json'
require 'thread'

class OsNode
  def initialize
    @queue = Queue.new
    @mutex = Mutex.new
    @ret = []
  end

  def run
    cts = JSON.parse(`osctl -j ct ls -S running`)
    cts.each_with_index { |ct, i| @queue << [ct, i] }
    @total = cts.length

    num_threads = [cts.length / 10, 1].max
    msg "Processing cts in #{num_threads} threads"

    num_threads.times.map do
      Thread.new { work_loop }
    end.each(&:join)

    puts @ret.to_json
  end

  protected
  def work_loop
    loop do
      begin
        ct, i = @queue.pop(true)
      rescue ThreadError
        return
      end

      process_ct(ct, i)
    end
  end

  def process_ct(ct, i)
    prefix = "[#{i+1}/#{@total}] #{ct['pool']}:#{ct['id']}:"
    msg "#{prefix} processing "
    
    os_release = `ct exec #{ct['pool']}:#{ct['id']} cat /etc/os-release 2>/dev/null`
    
    if $?.exitstatus != 0
      msg "#{prefix} failed to read /etc/os-release"
      os_release = nil
    end

    sync do
      @ret << {
        id: ct['id'],
        platform: 'vpsadminos',
        distribution: ct['distribution'],
        version: ct['version'],
        os_release: os_release,
      }
    end
  end

  def msg(str)
    sync { warn str }
  end

  def sync(&block)
    @mutex.synchronize(&block)
  end
end

n = OsNode.new
n.run
