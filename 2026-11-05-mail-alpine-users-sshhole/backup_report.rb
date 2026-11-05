# Fixed TSV output of disable_ssh_password_authentication.sh --report-backup.
module SshholeBackupReport
  def self.read(path)
    entries = {}
    File.foreach(path).with_index(1) do |line, number|
      version, node, pool, id, policy, digest, extra = line.chomp.split("\t", -1)
      valid = extra.nil? && version == 'ssh-password-backup-v1' &&
              node&.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/) &&
              pool&.match?(/\A[^\s\/]+\z/) && id&.match?(/\A[1-9][0-9]*\z/) &&
              %w(enabled disabled unknown).include?(policy) &&
              (digest&.match?(/\A[a-fA-F0-9]{64}\z/) || (policy == 'unknown' && digest == '-'))
      raise "Invalid backup report row #{number}" unless valid

      id = id.to_i
      entry = { node:, pool:, policy:, sha256: digest.downcase }
      prior = entries[id]
      raise "Conflicting backup report for VPS #{id}" if prior && prior != entry

      entries[id] = entry
    end
    entries
  end
end
