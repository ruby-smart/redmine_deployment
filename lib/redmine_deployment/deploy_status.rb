# frozen_string_literal: true

module RedmineDeployment
  # Deploy status of issues: "Code" (the issue has changesets), followed by the deploy environments of its project
  # (RedmineDeployment::Environments - the central ones or the project's own ones).
  #
  # A changeset is part of an environment
  # * deployment: if it is part of the commit range of a *successful* deployment of that environment - the same
  #   range as Deployment#changesets, i.e. <tt>git log from_revision..to_revision</tt>
  # * branch: if it is merged into the branch of its repository, i.e. an ancestor of the branch head
  #   (<tt>git branch --contains</tt>) - the branch head is read from the repository, its changeset has to be
  #   fetched into Redmine
  # An environment is
  # * reached, if all changesets of the issue are part of it
  # * partial, if only some of them are part of it
  #
  # "Live since" is the time, from which on all changesets were deployed to the last environment (unknown, if the
  # last environment is a branch).
  #
  # All issues are resolved at once (a handful of queries per project, no N+1). The commit range of a deployment and
  # the ancestors of a branch head never change, so they are computed once by a recursive SQL query and then cached.
  class DeployStatus
    Environment = Struct.new(:key, :label, :color, :covered, :total, keyword_init: true) do
      def state
        if covered.zero?
          :none
        elsif covered >= total
          :reached
        else
          :partial
        end
      end
    end

    # code: the step "Code" of the project (Environments::Code - label and color)
    Result = Struct.new(:changeset_count, :code, :environments, :live_since, keyword_init: true) do
      # number of the reached environments, counted from the start of the pipeline (0 = only "Code")
      def level
        index = environments.rindex { |environment| environment.state == :reached }
        index ? index + 1 : 0
      end

      # the last environment, that has (some) changesets of the issue
      def top
        index = environments.rindex { |environment| environment.state != :none }
        index ? index + 1 : 0
      end

      # true, if the last touched environment has only some changesets (newer commits are not deployed yet)
      def partial?
        top > level
      end

      def top_environment
        top.positive? ? environments[top - 1] : nil
      end

      # all changesets are deployed to the last environment
      def live?
        environments.any? && level == environments.size
      end
    end

    CACHE_NAMESPACE = 'redmine_deployment/commit_range'
    # a commit is expected to be deployed after it was committed - tolerance for clock skews
    COMMIT_TOLERANCE = 1.day

    attr_reader :issues, :user

    # @param [Array<Issue>] issues
    # @param [User] user - only issues of projects with the permission +view_deployments+ get a status
    # @param [Array<Environments::Environment>, nil] environments - the environments of all projects (default: the
    #   environments of each project, see Environments.for)
    def initialize(issues, user: User.current, environments: nil)
      @issues       = issues.to_a
      @user         = user
      @environments = environments&.to_a
    end

    # @return [Array<Environments::Environment>] the environments of the project (its own ones or the central ones)
    def environments_for(project)
      return @environments if @environments

      (@project_environments ||= {})[project.id] ||= Environments.for(project)
    end

    # @return [Environments::Code] the step "Code" of the project (its own pipeline or the central one)
    def code_for(project)
      return Environments::Code.new(nil, Environments::CODE_COLOR) if @environments

      (@project_codes ||= {})[project.id] ||= Environments.code_for(project)
    end

    # true, if deploy statuses are shown at all: the user may see the deployments of a project with environments and
    # there are branch environments or deployments
    def enabled?
      return @enabled if defined?(@enabled)

      @enabled = projects.any? &&
                 (projects.any? { |project| environments_for(project).any?(&:branch?) } ||
                  ::Deployment.where(project_id: projects.map(&:id)).exists?)
    end

    # @return [Result, nil] the deploy status of the issue (nil: disabled, not visible or no changesets)
    def [](issue)
      statuses[issue.is_a?(Issue) ? issue.id : issue.to_i]
    end

    # @return [Hash{Integer => Result}] deploy status by issue id
    def statuses
      @statuses ||= enabled? ? compute : {}
    end

    private

    # the projects of the issues, whose deployments are visible to the user and that have environments
    def projects
      @projects ||= issues.map(&:project).uniq.select do |project|
        user.allowed_to?(:view_deployments, project) && environments_for(project).any?
      end
    end

    def compute
      projects_by_id = projects.index_by(&:id)
      issue_projects = issues.select { |issue| projects_by_id.key?(issue.project_id) }.to_h { |issue| [issue.id, issue.project_id] }
      rows           = changeset_rows(issue_projects.keys)
      return {} if rows.empty?

      repositories = Repository.where(id: rows.map(&:third).uniq).index_by(&:id)

      rows.group_by { |row| issue_projects[row.first] }.each_with_object({}) do |(project_id, project_rows), statuses|
        environments = environments_for(projects_by_id[project_id])
        covering     = covering_deployments(project_rows, repositories, environments).
          merge(covering_branches(project_rows, repositories, environments))

        code = code_for(projects_by_id[project_id])
        project_rows.group_by(&:first).each do |issue_id, issue_rows|
          statuses[issue_id] = result_for(issue_rows.map(&:second).uniq, covering, environments, code)
        end
      end
    end

    def result_for(changeset_ids, covering, environments, code)
      states = environments.map do |environment|
        covered = changeset_ids.count { |changeset_id| covering.dig(environment.key, changeset_id).present? }
        Environment.new(key: environment.key, label: environment.label, color: environment.color, covered: covered,
                        total: changeset_ids.size)
      end

      result = Result.new(changeset_count: changeset_ids.size, code: code, environments: states)
      last   = environments.last
      if result.live? && last.deployment?
        # all changesets are live, as soon as the last of them was deployed for the first time
        result.live_since = changeset_ids.map { |changeset_id| covering[last.key][changeset_id].map(&:created_on).min }.max
      end
      result
    end

    # @return [Array<Array>] [issue_id, changeset_id, repository_id, committed_on]
    def changeset_rows(issue_ids)
      return [] if issue_ids.empty?

      Changeset.joins("INNER JOIN #{Changeset.table_name_prefix}changesets_issues#{Changeset.table_name_suffix} ci ON ci.changeset_id = #{Changeset.table_name}.id").
        where('ci.issue_id' => issue_ids).
        pluck(Arel.sql('ci.issue_id'), "#{Changeset.table_name}.id", "#{Changeset.table_name}.repository_id", "#{Changeset.table_name}.committed_on")
    end

    # @return [Hash{String => Hash{Integer => Array<Deployment>}}] successful deployments by environment key and
    #   changeset id
    def covering_deployments(rows, repositories, environments)
      keys = environments.select(&:deployment?).to_h { |environment| [environment.value, environment.key] }
      return {} if keys.empty?

      changeset_ids  = rows.to_set(&:second)
      repository_ids = rows.map(&:third).uniq
      committed_from = rows.map(&:fourth).compact.min

      deployments = ::Deployment.
        where(repository_id: repository_ids, environment: keys.keys, result: ::Deployment::RESULT_SUCCESS).
        select(:id, :repository_id, :environment, :from_revision, :to_revision, :created_on)
      deployments = deployments.where("#{::Deployment.table_name}.created_on >= ?", committed_from - COMMIT_TOLERANCE) if committed_from
      deployments = deployments.to_a

      covering = Hash.new { |hash, key| hash[key] = {} }
      return covering if deployments.empty?

      revisions = resolve_revisions(deployments, repositories)

      deployments.each do |deployment|
        repository = repositories[deployment.repository_id]
        next unless repository && dag_available?(repository)

        to_id = revisions[[repository.id, deployment.to_revision]]
        next unless to_id

        from_id = revisions[[repository.id, deployment.from_revision]]
        ids     = range_ids(to_id, from_id) { ::Deployment.find(deployment.id).changesets.pluck(:id) }
        ids.each do |changeset_id|
          next unless changeset_ids.include?(changeset_id)

          (covering[keys[deployment.environment]][changeset_id] ||= []) << deployment
        end
      end

      covering
    end

    # @return [Hash{String => Hash{Integer => true}}] changesets merged into the branches by environment key and
    #   changeset id
    def covering_branches(rows, repositories, environments)
      branch_environments = environments.select(&:branch?)
      return {} if branch_environments.empty?

      changeset_ids = rows.group_by(&:third).transform_values { |repository_rows| repository_rows.to_set(&:second) }

      branch_environments.to_h do |environment|
        covered = {}
        changeset_ids.each do |repository_id, repository_changeset_ids|
          repository = repositories[repository_id]
          next unless repository && dag_available?(repository)

          head = branch_head(repository, environment.value)
          next unless head

          ids = range_ids(head.id, nil) { ::Deployment.new(repository: repository, to_revision: head.revision).changesets.pluck(:id) }
          ids.each { |changeset_id| covered[changeset_id] = true if repository_changeset_ids.include?(changeset_id) }
        end
        [environment.key, covered]
      end
    end

    # @return [Changeset, nil] the head of the branch (nil: unknown branch or head not fetched into Redmine yet)
    def branch_head(repository, name)
      revision = branch_revisions(repository)[name]
      return unless revision

      @branch_heads ||= {}
      key = [repository.id, revision]
      return @branch_heads[key] if @branch_heads.key?(key)

      @branch_heads[key] = Changeset.where(repository_id: repository.id, revision: revision).select(:id, :repository_id, :revision).first
    end

    # The heads of the branches of the repository (<tt>git branch</tt>, once per repository and request).
    #
    # @return [Hash{String => String}] revision of the branch head by branch name
    def branch_revisions(repository)
      @branch_revisions ||= {}
      return @branch_revisions[repository.id] if @branch_revisions.key?(repository.id)

      @branch_revisions[repository.id] =
        begin
          Array(repository.branches).to_h { |branch| [branch.to_s, (branch.scmid.presence || branch.revision).to_s] }
        rescue StandardError => e
          # e.g. Redmine::Scm::Adapters::CommandFailed - a missing repository or git binary
          Rails.logger.warn("RedmineDeployment::DeployStatus: branches of repository #{repository.id}: #{e.message}")
          {}
        end
    end

    # Resolves the revisions of the deployments like Repository::Git#find_changeset_by_name (exact revision,
    # then scmid prefix) - the exact matches in one query.
    #
    # @return [Hash{[Integer, String] => Integer}] changeset id by [repository id, revision]
    def resolve_revisions(deployments, repositories)
      wanted = deployments.flat_map { |d| [[d.repository_id, d.from_revision], [d.repository_id, d.to_revision]] }.
        reject { |_, revision| revision.blank? }.uniq

      resolved = Changeset.where(repository_id: wanted.map(&:first).uniq, revision: wanted.map(&:second).uniq).
        pluck(:repository_id, :revision, :id).
        to_h { |repository_id, revision, id| [[repository_id, revision], id] }

      (wanted - resolved.keys).each do |repository_id, revision|
        changeset = repositories[repository_id]&.find_changeset_by_name(revision)
        resolved[[repository_id, revision]] = changeset.id if changeset
      end

      resolved
    end

    # the parent DAG is usable: a git repository with populated changeset parents (see Deployment#dag_available?)
    def dag_available?(repository)
      @dag_available ||= {}
      return @dag_available[repository.id] if @dag_available.key?(repository.id)

      @dag_available[repository.id] =
        repository.is_a?(Repository::Git) &&
        Changeset.where(repository_id: repository.id).
          joins("INNER JOIN #{parents_table} cp ON cp.changeset_id = #{Changeset.table_name}.id").exists?
    end

    # Ids of the changesets in the commit range from..to (inclusive to, exclusive from and its ancestors; without
    # from: all ancestors of to) - identical to Deployment#changesets, cached by the changeset ids.
    #
    # The block is the fallback, if the range can't be computed by SQL (it has to return the ids).
    def range_ids(to_id, from_id)
      Rails.cache.fetch([CACHE_NAMESPACE, to_id, from_id]) { compute_range_ids(to_id, from_id) }
    rescue ActiveRecord::StatementInvalid => e
      # e.g. a database without recursive CTEs - fall back to the (slower) DAG walk of Deployment#changesets
      Rails.logger.warn("RedmineDeployment::DeployStatus: #{e.message} - falling back to Deployment#changesets")
      yield
    end

    def compute_range_ids(to_id, from_id)
      connection = Changeset.connection
      prepare_recursion(connection)

      changesets = Changeset.table_name
      excluded   =
        if from_id
          <<~SQL
            excluded(id) AS (
              SELECT id FROM #{changesets} WHERE id = #{from_id.to_i}
              UNION
              SELECT cp.parent_id FROM #{parents_table} cp INNER JOIN excluded ON cp.changeset_id = excluded.id
            ),
          SQL
        end
      not_excluded = from_id ? ' AND id NOT IN (SELECT id FROM excluded)' : ''
      parent_not_excluded = from_id ? ' WHERE cp.parent_id NOT IN (SELECT id FROM excluded)' : ''

      sql = <<~SQL
        WITH RECURSIVE #{excluded}
        deployed(id) AS (
          SELECT id FROM #{changesets} WHERE id = #{to_id.to_i}#{not_excluded}
          UNION
          SELECT cp.parent_id FROM #{parents_table} cp INNER JOIN deployed ON cp.changeset_id = deployed.id#{parent_not_excluded}
        )
        SELECT id FROM deployed
      SQL

      connection.select_values(sql).map(&:to_i)
    end

    # MySQL aborts recursive CTEs after 1000 iterations by default - a linear git history is much deeper
    def prepare_recursion(connection)
      return unless connection.adapter_name.to_s.match?(/mysql/i)

      connection.execute('SET SESSION cte_max_recursion_depth = 4294967295')
    end

    def parents_table
      "#{Changeset.table_name_prefix}changeset_parents#{Changeset.table_name_suffix}"
    end
  end
end
