# frozen_string_literal: true

module RubysmartDeployment
  # The commit range of a deployment: the ids of the changesets reachable from +to+ by following the parent graph
  # (+changeset_parents+) minus the ones reachable from +from+ - <tt>git log from..to</tt>, exclusive of +from+,
  # inclusive of +to+. Without +from+ it is "all ancestors of +to+": the "merged into this branch head" question
  # of the branch steps of the deploy status.
  #
  # The range is computed by ONE recursive SQL query (MySQL 8 / MariaDB, PostgreSQL, SQLite - about 15 ms for a
  # history of 17,000 commits on MySQL 8, whatever the size of the range: both cones are walked down to the root),
  # falling back to a walk over the graph in Ruby - one query per generation of commits, thousands for a real
  # history - on a database without recursive CTEs.
  #
  # Neither runs in a request: the range of a deployment never changes, so it is stored once
  # (Deployment#resolve_changesets!, DeploymentChangeset); the ancestors of the branch heads / tag commits of a
  # pipeline step are cached by the step and its heads (DeployStatus#ref_ancestor_ids). The ancestors of several
  # heads at once - all branches / tags matching a step, e.g. hundreds of release tags - are ONE query as well
  # (+ancestors+), not one per head.
  module CommitRange
    # Defensive upper bound on how many changesets the Ruby walk visits, guarding against pathological histories.
    # Logged if hit; never silently truncated.
    MAX_TRAVERSAL = 50_000

    module_function

    # @param [Integer] to_id the changeset id of the upper boundary (inclusive)
    # @param [Integer, nil] from_id the changeset id of the lower boundary (exclusive) - nil: all ancestors of +to+
    # @return [Array<Integer>] the changeset ids of the range
    def ids(to_id, from_id = nil)
      return ancestors([to_id]) unless from_id

      sql_ids(to_id, from_id)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("RubysmartDeployment::CommitRange: #{e.message} - walking the commit graph in Ruby instead")
      walk_ids(to_id, from_id)
    end

    # All ancestors of the heads, inclusive of the heads: ONE recursive query whatever the number of heads - the
    # cones of the heads overlap (e.g. release tags on one line of history), UNION visits every commit once. Falls
    # back to a walk in Ruby like +ids+.
    #
    # @param [Array<Integer>] head_ids changeset ids (e.g. the commits of all tags matching a step)
    # @return [Array<Integer>] the changeset ids
    def ancestors(head_ids)
      head_ids = head_ids.map(&:to_i).uniq
      return [] if head_ids.empty?

      sql_ancestors(head_ids)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("RubysmartDeployment::CommitRange: #{e.message} - walking the commit graph in Ruby instead")
      walk_ancestors(head_ids).to_a
    end

    # True when the parent graph is usable for the repository: a git repository whose +changeset_parents+ edges
    # have actually been populated (Redmine fills them while fetching the changesets).
    def dag_available?(repository)
      repository.is_a?(Repository::Git) &&
        ChangesetParent.where(:changeset_id => Changeset.where(:repository_id => repository.id).select(:id)).exists?
    end

    # the range from..to by one recursive query - see +ids+ (without +from+: +ancestors+)
    def sql_ids(to_id, from_id)
      connection = Changeset.connection
      prepare_recursion(connection)

      changesets = Changeset.table_name
      sql = <<~SQL
        WITH RECURSIVE excluded(id) AS (
          SELECT id FROM #{changesets} WHERE id = #{from_id.to_i}
          UNION
          SELECT cp.parent_id FROM #{parents_table} cp INNER JOIN excluded ON cp.changeset_id = excluded.id
        ),
        deployed(id) AS (
          SELECT id FROM #{changesets} WHERE id = #{to_id.to_i} AND id NOT IN (SELECT id FROM excluded)
          UNION
          SELECT cp.parent_id FROM #{parents_table} cp INNER JOIN deployed ON cp.changeset_id = deployed.id
            WHERE cp.parent_id NOT IN (SELECT id FROM excluded)
        )
        SELECT id FROM deployed
      SQL

      connection.select_values(sql).map(&:to_i)
    end

    # the ancestors of the heads by one recursive query - see +ancestors+
    def sql_ancestors(head_ids)
      connection = Changeset.connection
      prepare_recursion(connection)

      sql = <<~SQL
        WITH RECURSIVE reachable(id) AS (
          SELECT id FROM #{Changeset.table_name} WHERE id IN (#{head_ids.join(', ')})
          UNION
          SELECT cp.parent_id FROM #{parents_table} cp INNER JOIN reachable ON cp.changeset_id = reachable.id
        )
        SELECT id FROM reachable
      SQL

      connection.select_values(sql).map(&:to_i)
    end

    # the range by a walk over the graph in Ruby: one query per generation of commits - see +ids+
    def walk_ids(to_id, from_id)
      excluded = from_id ? walk_ancestors([from_id]) : Set.new
      result   = Set.new
      visited  = Set.new([to_id])
      frontier = [to_id]

      while frontier.any? && result.size < MAX_TRAVERSAL
        frontier.each { |id| result << id unless excluded.include?(id) }
        frontier = parent_ids_for(frontier).reject { |id| visited.include?(id) || excluded.include?(id) }
        visited.merge(frontier)
      end

      warn_traversal_cap(to_id, 'walk_ids') if result.size >= MAX_TRAVERSAL
      result.to_a
    end

    # all ancestor ids of the seeds, inclusive of the seeds themselves - by a walk in Ruby (see +ancestors+)
    #
    # @return [Set<Integer>]
    def walk_ancestors(seed_ids)
      visited  = Set.new(seed_ids)
      frontier = seed_ids

      while frontier.any? && visited.size < MAX_TRAVERSAL
        frontier = parent_ids_for(frontier).reject { |id| visited.include?(id) }
        visited.merge(frontier)
      end

      warn_traversal_cap(seed_ids.first, 'walk_ancestors') if visited.size >= MAX_TRAVERSAL
      visited
    end

    def parent_ids_for(changeset_ids)
      return [] if changeset_ids.empty?

      ChangesetParent.where(:changeset_id => changeset_ids).distinct.pluck(:parent_id)
    end

    # MySQL aborts recursive CTEs after 1000 iterations by default (cte_max_recursion_depth; MariaDB:
    # max_recursive_iterations) - a linear git history is much deeper. A server that knows neither variable is
    # left alone.
    def prepare_recursion(connection)
      return unless connection.adapter_name.to_s.match?(/mysql/i)

      %w[cte_max_recursion_depth max_recursive_iterations].each do |variable|
        connection.execute("SET SESSION #{variable} = 4294967295")
        break
      rescue ActiveRecord::StatementInvalid
        next
      end
    end

    def warn_traversal_cap(changeset_id, context)
      Rails.logger.warn(
        "RubysmartDeployment::CommitRange: #{context} of changeset #{changeset_id} hit MAX_TRAVERSAL " \
        "(#{MAX_TRAVERSAL}); the range may be incomplete."
      )
    end

    def parents_table
      "#{Changeset.table_name_prefix}changeset_parents#{Changeset.table_name_suffix}"
    end
  end
end
