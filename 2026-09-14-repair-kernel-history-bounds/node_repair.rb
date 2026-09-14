# frozen_string_literal: true

require 'time'
require_relative 'runner'
require 'vpsadmin/api/kernel_evidence/stable_state'

module KernelHistoryBoundsRepair
  KernelEvidence = VpsAdmin::API::KernelEvidence

  class NodeRepair
    def self.run(**) = new.run(**)

    Proposal = Data.define(:event_id, :before, :after, :upper, :evidence_id, :fingerprint, :reason)

    def run(
      node:,
      ids: nil,
      apply: false,
      batch_size: DEFAULT_BATCH_SIZE,
      io: $stdout
    )
      raise ArgumentError, 'Batch size must be a positive integer' unless batch_size.is_a?(Integer) && batch_size > 0

      @node = node
      @batch_size = batch_size
      totals = { candidates: 0, proposed: 0, applied: 0, skipped: 0 }
      # Freeze membership before the first batch, including events we must
      # explain skipping. New reports cannot extend this run indefinitely.
      ids ||= node.node_kernel_events.kernel_history.order(:id).pluck(:id)
      io.puts "Node #{node.id}: #{apply ? 'apply' : 'dry-run'}, #{ids.length} candidates, batch size #{batch_size}"
      ids.each_slice(batch_size) do |batch|
        batch.each do |id|
          totals[:candidates] += 1
          proposal = inspect_event(id)
          if proposal.reason
            totals[:skipped] += 1
            print_proposal(io, proposal, "skip: #{proposal.reason}")
            next
          end

          if apply
            applied = apply_proposal(proposal)
            unless applied
              totals[:skipped] += 1
              print_proposal(io, proposal, 'skip: concurrent change')
              next
            end
            totals[:applied] += 1
          end
          totals[:proposed] += 1
          print_proposal(io, proposal, apply ? 'applied' : 'would tighten')
        end
      end
      io.puts "Node #{@node.id} totals: #{totals.map { |key, value| "#{key}=#{value}" }.join(' ')}"
      totals
    end

    protected

    def inspect_event(id)
      event = @node.node_kernel_events.find_by(id:)
      values = { event_id: id, before: event&.observed_after, after: nil,
                 upper: event&.observed_before, evidence_id: nil, fingerprint: nil }
      reason = skip_reason(event)
      return Proposal.new(**values, reason:) if reason

      predecessor = @node.node_kernel_events.kernel_history
                         .where('observed_before < :time OR (observed_before = :time AND id < :id)',
                                time: event.observed_before, id: event.id)
                         .order(observed_before: :desc, id: :desc).first
      return Proposal.new(**values, reason: 'missing preceding public baseline') unless predecessor

      baseline = immutable_report(predecessor)
      target = immutable_report(event)
      unless baseline && target && KernelEvidence::StableState.stable?(baseline) &&
             KernelEvidence::StableState.stable?(target)
        return Proposal.new(**values, reason: 'incomplete, missing, or altered immutable baseline/target evidence')
      end
      unless KernelEvidence::StableState.same_boot?(baseline.kernel, target.kernel)
        return Proposal.new(**values, reason: 'different or unknown boot')
      end
      unless classification_matches?(event, baseline, target)
        return Proposal.new(**values, reason: 'ambiguous event classification')
      end

      evidence = confirming_evidence(event, predecessor, baseline)
      return Proposal.new(**values, reason: 'no retained stable confirmation inside bounds') unless evidence

      Proposal.new(
        **values, after: evidence.observed_at, evidence_id: evidence.id,
                  fingerprint: [event.attributes, predecessor.attributes,
                                event.kernel_evidence.attributes, target.digest,
                                predecessor.kernel_evidence.attributes, baseline.digest,
                                evidence.attributes, KernelEvidence::SnapshotReader.call(evidence).digest],
                  reason: nil
      )
    end

    def skip_reason(event)
      return 'event disappeared' unless event
      return 'boot event' if event.boot?
      return 'not inferred node-reported history' unless event.node_report? && event.inferred?
      return 'missing lower bound' unless event.observed_after
      return 'invalid interval' unless event.observed_after < event.observed_before
      return 'ambiguous livepatch classification' if event.livepatch_change? && event.livepatch_action.nil?

      nil
    end

    def immutable_report(event)
      snapshot = event.kernel_evidence
      return unless snapshot&.event? && snapshot.node_id == @node.id
      return unless snapshot.observed_at == event.observed_before

      verified_snapshot_report(snapshot)
    end

    def verified_snapshot_report(snapshot)
      report = KernelEvidence::SnapshotReader.call(snapshot)
      report if report.digest == snapshot.snapshot_revision
    rescue ArgumentError, KeyError, TypeError
      nil
    end

    def classification_matches?(event, baseline, target)
      previous_ids = KernelEvidence::StableState.effective_ids(baseline.livepatches)
      current_ids = KernelEvidence::StableState.effective_ids(target.livepatches)
      if event.reported_release_change?
        baseline.kernel.reported_release != target.kernel.reported_release && previous_ids == current_ids
      elsif event.livepatch_applied?
        (current_ids - previous_ids).any?
      elsif event.livepatch_removed?
        (current_ids - previous_ids).empty? && (previous_ids - current_ids).any?
      else
        false
      end
    end

    def confirming_evidence(event, predecessor, baseline)
      scope = ::NodeKernelEvidence.event.where(node_id: @node.id)
                                  .where(id: @node.node_kernel_events.select(:node_kernel_evidence_id))
                                  .where('observed_at > ? AND observed_at < ?',
                                         event.observed_after, event.observed_before)
                                  .where('observed_at >= ?', predecessor.observed_before)
      loop do
        batch = scope.order(observed_at: :desc, id: :desc).limit(@batch_size).to_a
        batch.each do |snapshot|
          report = verified_snapshot_report(snapshot)
          return snapshot if KernelEvidence::StableState.confirms?(baseline, report)
        end
        return if batch.length < @batch_size

        last = batch.last
        scope = scope.where('observed_at < :time OR (observed_at = :time AND id < :id)',
                            time: last.observed_at, id: last.id)
      end
    end

    def apply_proposal(proposal)
      @node.with_lock do
        return false unless @node.node? || @node.storage?
        return false unless inspect_event(proposal.event_id) == proposal

        @node.node_kernel_events.find(proposal.event_id).update!(observed_after: proposal.after)
        true
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    def print_proposal(io, proposal, status)
      io.puts "node=#{@node.id} event=#{proposal.event_id} old=(#{format_time(proposal.before)}, #{format_time(proposal.upper)}] " \
              "proposed=(#{format_time(proposal.after || proposal.before)}, #{format_time(proposal.upper)}] " \
              "evidence=#{proposal.evidence_id || '-'} #{status}"
    end

    def format_time(value)
      value ? value.utc.iso8601(6) : '-'
    end
  end
end
