require 'digest'
require 'json'
require 'securerandom'
require 'time'

module StorageInventory
  VERSION = 2
  MAX_RECORDS = 250_000
  MAX_BYTES = 128 * 1024 * 1024

  def self.now
    Time.now.utc.iso8601(6)
  end

  def self.valid_path!(name)
    raise ArgumentError, "invalid ZFS path: #{name.inspect}" unless
      name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.:\-]+(?:\/[A-Za-z0-9_.:\-]+)*\z/) &&
      !name.split('/').include?('..')

    name
  end

  def self.each_bounded_line(io, max_lines: MAX_RECORDS * 4)
    bytes = 0
    lines = 0
    buffer = +''
    loop do
      chunk = io.readpartial(16_384)
      bytes += chunk.bytesize
      raise ArgumentError, 'command output byte limit exceeded' if bytes > MAX_BYTES
      buffer << chunk
      while (index = buffer.index("\n"))
        line = buffer.slice!(0, index + 1)
        lines += 1
        raise ArgumentError, 'command output record limit exceeded' if lines > max_lines
        yield line.chomp.force_encoding('UTF-8')
      end
    end
  rescue EOFError
    raise ArgumentError, 'command output ended mid-line' unless buffer.empty?
  end

  def self.stderr_summary(io)
    summary = +''
    while (chunk = io.read(4096))
      summary << chunk.byteslice(0, [1000 - summary.bytesize, 0].max) if summary.bytesize < 1000
    end
    summary
  end

  class Writer
    attr_reader :counts

    def initialize(path, header)
      raise ArgumentError, 'output already exists' if File.exist?(path)

      @path = path
      @tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{SecureRandom.hex(8)}.tmp")
      @file = File.open(@tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      @digest = Digest::SHA256.new
      @counts = Hash.new(0)
      @bytes = 0
      line = JSON.generate(header.merge('record' => 'header', 'version' => VERSION)) + "\n"
      @file.write(line)
      @digest.update(line)
    end

    def add(type, data)
      raise ArgumentError, 'record limit exceeded' if @counts.values.sum >= MAX_RECORDS

      line = JSON.generate('record' => type, 'data' => data) + "\n"
      raise ArgumentError, 'capture byte limit exceeded' if @bytes + line.bytesize > MAX_BYTES

      @file.write(line)
      @digest.update(line)
      @bytes += line.bytesize
      @counts[type] += 1
    end

    def finish(extra = {})
      trailer = { 'record' => 'trailer', 'finished_at' => StorageInventory.now,
                  'counts' => @counts.sort.to_h }.merge(extra)
      @digest.update(JSON.generate(trailer) + "\n")
      write_raw(trailer.merge('sha256' => @digest.hexdigest))
      @file.flush
      @file.fsync
      @file.close
      # link fails if another process created the destination in the meantime.
      File.link(@tmp, @path)
      File.unlink(@tmp)
      @tmp = nil
    end

    def abort
      @file.close unless @file.closed?
      File.unlink(@tmp) if @tmp && File.exist?(@tmp)
    end

    private

    def write_raw(obj)
      @file.write(JSON.generate(obj) + "\n")
    end
  end

  class Reader
    attr_reader :header, :trailer, :records

    def initialize(path, kind)
      @records = Hash.new { |h, k| h[k] = [] }
      digest = Digest::SHA256.new
      counts = Hash.new(0)
      bytes = 0
      File.foreach(path) do |line|
        bytes += line.bytesize
        raise ArgumentError, 'capture byte limit exceeded' if bytes > MAX_BYTES
        obj = JSON.parse(line)
        case obj.fetch('record')
        when 'header'
          raise ArgumentError, 'duplicate header' if @header || @trailer
          @header = obj
          digest.update(line)
        when 'trailer'
          raise ArgumentError, 'duplicate trailer' if @trailer
          @trailer = obj
          digest.update(JSON.generate(obj.reject { |key, _| key == 'sha256' }) + "\n")
        else
          raise ArgumentError, 'record outside capture' unless @header && !@trailer
          type = obj.fetch('record')
          @records[type] << obj.fetch('data')
          counts[type] += 1
          raise ArgumentError, 'record limit exceeded' if counts.values.sum > MAX_RECORDS
          digest.update(line)
        end
      end
      raise ArgumentError, 'incomplete capture' unless @header && @trailer
      raise ArgumentError, 'unsupported capture' unless @header['version'] == VERSION && @header['kind'] == kind
      raise ArgumentError, 'capture checksum/count mismatch' unless
        @trailer['sha256'] == digest.hexdigest && @trailer['counts'] == counts.sort.to_h
      raise ArgumentError, 'missing observation window' unless
        @header['started_at'].is_a?(String) && @trailer['finished_at'].is_a?(String)
      raise ArgumentError, 'invalid observation window' unless
        [@header['started_at'], @trailer['finished_at']].all? { |value| Time.iso8601(value) rescue false }
      raise ArgumentError, 'invalid capture scope' unless @header['scope'].is_a?(Hash)
      if kind == 'db'
        raise ArgumentError, 'invalid DB scope or node record' unless
          @header['scope']['node_id'].is_a?(Integer) && @header['scope']['node_id'].positive? &&
          counts['node'] == 1 && counts['observation'] == 1 && counts['pool'].positive?
      end
      if kind == 'zfs'
        roots = @header['scope']['roots']
        raise ArgumentError, 'invalid ZFS roots' unless roots.is_a?(Array) && !roots.empty? &&
          roots == roots.uniq.sort && roots.all? { |root| StorageInventory.valid_path!(root) }
        raise ArgumentError, 'invalid ZFS volatility metadata' unless
          @trailer['volatile'] == (counts['scan_change'] > 0)
        raise ArgumentError, 'missing ZFS host' unless @header['host'].is_a?(String) && !@header['host'].empty?
        raise ArgumentError, 'missing ZFS scan window' unless
          %w[first_scan_finished_at second_scan_started_at second_scan_finished_at].all? do |key|
            Time.iso8601(@trailer.fetch(key)) rescue false
          end
      end
    end
  end
end
