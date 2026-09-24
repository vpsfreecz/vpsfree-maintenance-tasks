require 'optparse'
require_relative 'inventory'

module StorageInventory
  class DbCapture
    BATCH_SIZE = 1_000
    ID_BATCH_SIZE = 500
    MAX_CAPTURE_SECONDS = 15 * 60
    STATEMENT_TIMEOUT_SECONDS = 30
    SERVER_CLOCK_SQL = "SELECT DATE_FORMAT(UTC_TIMESTAMP(6), '%Y-%m-%dT%H:%i:%s.%fZ')".freeze

    MODEL_NAMES = {
      node: 'Node', pool: 'Pool', dataset_in_pool: 'DatasetInPool',
      dataset: 'Dataset', tree: 'DatasetTree', branch: 'Branch',
      snapshot: 'Snapshot', snapshot_in_pool: 'SnapshotInPool',
      snapshot_in_branch: 'SnapshotInPoolInBranch', clone: 'SnapshotInPoolClone',
      resource_lock: 'ResourceLock', maintenance_lock: 'MaintenanceLock'
    }.freeze

    def self.api_models
      MODEL_NAMES.transform_values { |name| Object.const_get(name) }
    end

    def self.cli(argv)
      options = {}
      OptionParser.new do |o|
        o.banner = 'Usage: capture_db.rb --node-id ID --output capture.jsonl'
        o.on('--node-id ID', Integer) { |v| options[:node_id] = v }
        o.on('--output PATH') { |v| options[:output] = v }
      end.parse!(argv)
      raise ArgumentError, 'unexpected arguments' unless argv.empty?
      raise ArgumentError, 'positive --node-id required' unless options[:node_id].to_i.positive?
      raise ArgumentError, '--output required' unless options[:output]

      require 'vpsadmin'
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        ActiveRecord::Base.uncached do
          new(node_id: options[:node_id], output: options[:output],
              connection: connection, models: api_models).run
        end
      end
    end

    def initialize(node_id:, output:, connection:, models:)
      @node_id = node_id
      @output = output
      @connection = connection
      @models = models
    end

    def run
      writer = Writer.new(@output,
        'kind' => 'db', 'started_at' => StorageInventory.now,
        'scope' => { 'node_id' => @node_id, 'pool_role' => 'backup' },
        'consistency' => 'one repeatable-read, read-only consistent InnoDB snapshot via vpsAdmin models')
      begin
        raise 'DB connection already has an open transaction' unless @connection.open_transactions.zero?
        raise 'model uses a different DB connection' unless
          @models.values.all? { |model| model.connection.equal?(@connection) }

        @raw_connection = @connection.raw_connection
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_CAPTURE_SECONDS
        previous_timeout = @connection.select_value('SELECT @@SESSION.max_statement_time')
        @connection.execute("SET SESSION max_statement_time = #{STATEMENT_TIMEOUT_SECONDS}")
        started = false
        begin
          # Model reads stay on this connection. Transaction control is the
          # only SQL issued directly by the collector.
          @connection.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
          @connection.execute('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY')
          started = true
          check_connection!
          observed_started_at = StorageInventory.now
          server_started_at = server_time
          server_connection_id = connection_id
          capture_rows(writer)
          check_connection!
          server_finished_at = server_time
          raise 'DB connection changed during capture' unless connection_id == server_connection_id
          writer.add('observation', 'server_time_utc' => server_started_at,
                                    'server_finished_at_utc' => server_finished_at,
                                    'connection_id' => server_connection_id,
                                    'collector_time_utc' => observed_started_at,
                                    'collector_finished_at_utc' => StorageInventory.now)
        ensure
          @connection.execute('ROLLBACK') if started
          raise 'DB connection changed during capture' unless
            @connection.raw_connection.equal?(@raw_connection)
          @connection.execute("SET SESSION max_statement_time = #{Float(previous_timeout)}")
        end
        writer.finish
      rescue StandardError
        writer.abort
        raise
      end
    end

    private

    def capture_rows(writer)
      node = @models.fetch(:node).includes(location: :environment).find(@node_id)
      writer.add('node', 'id' => node.id, 'name' => node.name,
                         'location_domain' => node.location_domain, 'fqdn' => node.fqdn)

      pool_ids = []
      capture_relation(writer, 'pool', @models.fetch(:pool).where(node_id: @node_id, role: :backup),
        %i[id node_id role filesystem is_open maintenance_lock state]) do |row|
        row['role'] = enum_number(row['role'], @models.fetch(:pool).roles)
        row['state'] = enum_number(row['state'], @models.fetch(:pool).states)
        pool_ids << row['id']
      end
      raise 'no backup pools found for node' if pool_ids.empty?

      dip_ids = []
      dataset_ids = []
      capture_scoped(writer, 'dataset_in_pool', :dataset_in_pool, :pool_id, pool_ids,
        %i[id pool_id dataset_id confirmed]) do |row|
        dip_ids << row['id']
        dataset_ids << row['dataset_id']
      end
      dataset_ids.uniq!
      capture_scoped(writer, 'dataset', :dataset, :id, dataset_ids,
        %i[id full_name confirmed object_state]) do |row|
        row['object_state'] = enum_number(row['object_state'], @models.fetch(:dataset).object_states)
      end

      tree_ids = []
      capture_scoped(writer, 'tree', :tree, :dataset_in_pool_id, dip_ids,
        %i[id dataset_in_pool_id index head confirmed]) do |row|
        row['head'] = boolean_number(row['head'])
        tree_ids << row['id']
      end
      branch_ids = []
      capture_scoped(writer, 'branch', :branch, :dataset_tree_id, tree_ids,
        %i[id dataset_tree_id name index head confirmed]) do |row|
        row['head'] = boolean_number(row['head'])
        branch_ids << row['id']
      end

      capture_scoped(writer, 'snapshot', :snapshot, :dataset_id, dataset_ids,
        %i[id dataset_id name history_id confirmed created_at])
      sip_ids = []
      capture_scoped(writer, 'snapshot_in_pool', :snapshot_in_pool, :dataset_in_pool_id, dip_ids,
        %i[id dataset_in_pool_id snapshot_id reference_count mount_id confirmed]) do |row|
        sip_ids << row['id']
      end
      sipb_ids = []
      capture_scoped(writer, 'snapshot_in_branch', :snapshot_in_branch, :snapshot_in_pool_id, sip_ids,
        %i[id branch_id snapshot_in_pool_id snapshot_in_pool_in_branch_id confirmed]) do |row|
        sipb_ids << row['id']
      end
      clone_ids = []
      capture_scoped(writer, 'clone', :clone, :snapshot_in_pool_id, sip_ids,
        %i[id snapshot_in_pool_id name state confirmed]) do |row|
        row['state'] = enum_number(row['state'], @models.fetch(:clone).states)
        clone_ids << row['id']
      end

      scopes = {
        'Node' => [@node_id], 'Pool' => pool_ids, 'Dataset' => dataset_ids,
        'DatasetInPool' => dip_ids, 'DatasetTree' => tree_ids, 'Branch' => branch_ids,
        'SnapshotInPool' => sip_ids, 'SnapshotInPoolInBranch' => sipb_ids,
        'SnapshotInPoolClone' => clone_ids
      }
      scopes.each do |resource, ids|
        capture_scoped(writer, 'resource_lock', :resource_lock, :row_id, ids,
          %i[id resource row_id locked_by_id locked_by_type created_at updated_at],
          resource: resource)
      end
      scopes.slice('Node', 'Pool', 'Dataset', 'DatasetInPool').each do |class_name, ids|
        capture_scoped(writer, 'maintenance_lock', :maintenance_lock, :row_id, ids,
          %i[id class_name row_id active created_at updated_at],
          class_name: class_name) do |row|
          row['active'] = boolean_number(row['active'])
        end
      end
    end

    def capture_scoped(writer, type, model_name, key, ids, fields, filters = {}, &block)
      ids.uniq.each_slice(ID_BATCH_SIZE) do |slice|
        relation = @models.fetch(model_name).where(filters).where(key => slice)
        capture_relation(writer, type, relation, fields, &block)
      end
    end

    def capture_relation(writer, type, relation, fields)
      relation.in_batches(of: BATCH_SIZE) do |batch|
        check_connection!
        batch.pluck(*fields).each do |values|
          check_deadline!
          row = fields.zip(values).to_h.transform_keys(&:to_s)
          row.transform_values! { |value| value.is_a?(Time) ? value.getutc.iso8601(6) : value }
          yield row if block_given?
          writer.add(type, row)
        end
        check_connection!
      end
    end

    def check_connection!
      raise 'DB connection changed during capture' unless
        @connection.raw_connection.equal?(@raw_connection)
      check_deadline!
    end

    def check_deadline!
      raise 'DB capture exceeded 15-minute limit' if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline
    end

    def server_time
      value = @connection.select_value(SERVER_CLOCK_SQL)
      Time.iso8601(value).utc.iso8601(6)
    end

    def connection_id
      id = Integer(@connection.select_value('SELECT CONNECTION_ID()'))
      raise 'invalid DB connection ID' unless id.positive?

      id
    end

    def enum_number(value, mapping)
      value.is_a?(String) ? mapping.fetch(value) : value
    end

    def boolean_number(value)
      value == true ? 1 : value == false ? 0 : value
    end
  end
end
