#!/run/nodectl/nodectl script
# Can be used to process transactions for a given node. All transactions are
# considered as NoOp and thus always succeed. Can be used to temporarily bypass
# offline node, however with consequences -- since the transactions are not
# executed, the state of the database will not correspond with the node.
#
require 'nodectld/standalone'

NODE_ID = 170

db = NodeCtld::Db.new
log = File.open('executed-transactions.txt', 'a')

loop do
  rows = db.union do |u|
    # Transactions for execution
    u.query(
      "SELECT * FROM (
        (SELECT t1.*, 1 AS depencency_success,
                ch1.state AS chain_state, ch1.progress AS chain_progress,
                ch1.size AS chain_size
        FROM transactions t1
        INNER JOIN transaction_chains ch1 ON ch1.id = t1.transaction_chain_id
        WHERE
            done = 0 AND node_id = #{NODE_ID}
            AND ch1.state = 1
            AND depends_on_id IS NULL
        GROUP BY transaction_chain_id, priority, t1.id)

        UNION ALL

        (SELECT t2.*, d.status AS dependency_success,
                ch2.state AS chain_state, ch2.progress AS chain_progress,
                ch2.size AS chain_size
        FROM transactions t2
        INNER JOIN transactions d ON t2.depends_on_id = d.id
        INNER JOIN transaction_chains ch2 ON ch2.id = t2.transaction_chain_id
        WHERE
            t2.done = 0
            AND d.done = 1
            AND t2.node_id = #{NODE_ID}
            AND ch2.state = 1
            GROUP BY transaction_chain_id, priority, id)

        ORDER BY priority DESC, id ASC
      ) tmp
      GROUP BY transaction_chain_id, priority
      ORDER BY priority DESC, id ASC
      LIMIT 1"
    )

    # Transactions for rollback.
    # It is the same query, only transactions are in reverse order.
    u.query(
      "SELECT * FROM (
        (SELECT d.*,
                ch2.state AS chain_state, ch2.progress AS chain_progress,
                ch2.size AS chain_size, ch2.urgent_rollback AS chain_urgent_rollback
        FROM transactions t2
        INNER JOIN transactions d ON t2.depends_on_id = d.id
        INNER JOIN transaction_chains ch2 ON ch2.id = t2.transaction_chain_id
        WHERE
            t2.done = 2
            AND d.status IN (1,2)
            AND d.done = 1
            AND d.node_id = #{NODE_ID}
            AND ch2.state = 3)

        ORDER BY priority DESC, id DESC
      ) tmp
      GROUP BY transaction_chain_id, priority
      ORDER BY priority DESC, id DESC
      LIMIT 1"
    )
  end

  rows.each do |row|
    puts "Executing transaction #{row['id']}"

    # Make it into a noop
    row['handle'] = 10001
    log.puts(row['id'])
    log.flush
    
    c = NodeCtld::Command.new(row)
    c.execute
    c.save(db)
  end

  sleep(1)
end

log.close
