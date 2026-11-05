# Only explicit terminal outcomes from the SSH maintenance task are evidence.
module SshholeRunLog
  def self.read(path)
    entries = {}
    current = nil
    finish = lambda do
      next unless current

      prior = entries[current[:id]]
      raise "Conflicting log records for VPS #{current[:id]}" if prior && prior != current

      entries[current[:id]] = current
    end

    File.foreach(path).with_index(1) do |line, number|
      line = line.strip
      if (match = /\A([^\s\/]+)\/([1-9][0-9]*)\z/.match(line))
        finish.call
        current = { pool: match[1], id: match[2].to_i, outcome: :incomplete }
        next
      end

      outcome = case line
                when /\Achanged; sshd restarted; original backup: \/etc\/ssh\/sshd_config\.before-2026-11-05-disable-password-authentication\z/
                  :changed
                when 'unchanged'
                  :unchanged
                else
                  if (match = /\Afailed: ([^\s\/]+)\/([1-9][0-9]*)\z/.match(line))
                    unless current && current[:pool] == match[1] && current[:id] == match[2].to_i
                      raise "Mismatching failure identity at line #{number}"
                    end
                    :failed
                  end
                end
      next unless outcome
      raise "Result without container at line #{number}" unless current
      if current[:outcome] != :incomplete && current[:outcome] != outcome
        raise "Conflicting results for VPS #{current[:id]} at line #{number}"
      end

      current[:outcome] = outcome
    end
    finish.call
    entries
  end
end
