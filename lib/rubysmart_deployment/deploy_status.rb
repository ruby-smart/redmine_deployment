# frozen_string_literal: true

module RubysmartDeployment
  # Deploy status of issues: "Code" (the issue has changesets), followed by the deploy environments of its project
  # (RubysmartDeployment::Environments - the central ones or the project's own ones).
  #
  # A changeset is part of an environment
  # * deployment: if it is part of the commit range of a *successful* deployment of that environment - the same
  #   range as Deployment#changesets, i.e. <tt>git log from_revision..to_revision</tt>
  # * branch: if it is merged into the branch of its repository, i.e. an ancestor of the branch head
  #   (<tt>git branch --contains</tt>) - the branch head is read from the repository, its changeset has to be
  #   fetched into Redmine
  # * tag: if it is part of a tag of its repository, i.e. an ancestor of the commit of the tag
  #   (<tt>git tag --contains</tt>) - like a branch, the commit has to be fetched into Redmine
  # An environment is
  # * reached, if all changesets of the issue are part of it
  # * partial, if only some of them are part of it
  #
  # The value of an environment can be dynamic (wildcards, placeholders of issue attributes - see
  # Environments::Environment#target), so it is resolved for each issue: a branch / tag environment is reached by the
  # branches / tags matching it (e.g. "feature/*" - any of them), a deployment environment by the deployments of the
  # matching environments.
  #
  # "Live since" is the time, from which on all changesets were deployed to the last environment (unknown, if the
  # last environment is a branch or a tag).
  #
  # With the plugin setting "respect_start_date" (off by default) only the changesets committed on or after the start
  # date of the issue count (from midnight in the time zone of the user - see +counting_since+) - older commits
  # referencing it (e.g. of a former use of the issue) are ignored.
  #
  # All issues are resolved at once (a handful of queries per project, no N+1) and nothing walks the commit graph
  # here: the changesets of a deployment are stored (DeploymentChangeset, resolved once in the background - see
  # Deployment#resolve_changesets!) and read by one indexed query; the ancestors of the branch heads / tag commits
  # of a step only change when a head moves on, so they are computed by a recursive SQL query
  # (RubysmartDeployment::CommitRange) and cached - one entry per step and repository, replaced when its heads change.
  # A branch / tag step costs the same whatever the number of branches / tags matching it (e.g. "/^v\d+/" and
  # thousands of release tags): one query for their changesets and ONE recursive query for their ancestors. The
  # branches and tags of a repository are read from git once per REFS_EXPIRES_IN (or when it fetched new commits),
  # not in every request; the regular expressions of the settings match within a time budget per deploy status
  # (Environments::MatchBudget).
  class DeployStatus
    # target: the value of the environment resolved for the issue (e.g. "feature/42-*" for "feature/{%issue.id%}-*")
    Environment = Struct.new(:key, :label, :color, :target, :covered, :total, keyword_init: true) do
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

    CACHE_NAMESPACE = 'rubysmart_deployment/commit_range'
    # the ancestors of a step: replaced when its heads change, dropped when unused this long (e.g. the feature branch
    # of a closed issue)
    CACHE_EXPIRES_IN = 7.days
    # the branches / tags of a repository (git): read again after this time at the latest - at once, when the
    # repository fetched new commits
    REFS_EXPIRES_IN = 5.minutes
    # the revisions of the branches / tags looked up by one query each (an IN list of this size at most)
    REVISION_BATCH = 500

    # the permission, that shows the deploy status on the issue page and in the issue query columns
    INDICATOR_PERMISSION = :view_deployment_indicator

    attr_reader :issues, :user, :permission

    # @param [Array<Issue>] issues
    # @param [User] user - only issues of projects with the permission get a status
    # @param [Symbol, Array<Symbol>] permission - the permission the user needs in the project of an issue (one of them:
    #   any); +view_deployments+ by default (e.g. the SCRUM taskboard), +view_deployment_indicator+ for the issue page
    #   and the issue query columns (INDICATOR_PERMISSION)
    # @param [Array<Environments::Environment>, nil] environments - the environments of all projects (default: the
    #   environments of each project, see Environments.for)
    def initialize(issues, user: User.current, permission: :view_deployments, environments: nil)
      @issues       = issues.to_a
      @user         = user
      @permission   = permission
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

    # True, if deploy statuses are shown at all: the user may see the deploy status of a project with environments and
    # there are branch / tag environments or successful deployments. A failed deployment is none - nothing of it counts
    # towards the pipeline (see +covering_deployments+).
    def enabled?
      return @enabled if defined?(@enabled)

      @enabled = projects.any? &&
                 (projects.any? { |project| environments_for(project).any?(&:ref?) } ||
                  ::Deployment.where(project_id: projects.map(&:id), result: ::Deployment::RESULT_SUCCESS).exists?)
    end

    # @return [Result, nil] the deploy status of the issue (nil: disabled, not visible or no changesets)
    def [](issue)
      statuses[issue.is_a?(Issue) ? issue.id : issue.to_i]
    end

    # @return [Hash{Integer => Result}] deploy status by issue id
    def statuses
      @statuses ||= enabled? ? compute : {}
    end

    # From when on the changesets of an issue count (plugin setting "respect_start_date", see
    # DeploymentSetting.respect_start_date?): the beginning of its start date in the time zone of the user - the
    # server's, if the user has none (like Redmine shows the times). The deploy status and the deployments of an issue
    # (Issue#deployments) use it alike.
    #
    # @return [Time, nil] nil: all changesets count (the setting is off or the issue has no start date)
    # +user+ defaults to the current user - looked up only with the option on (it costs a query without a request)
    def self.counting_since(issue, user = nil)
      return unless issue&.start_date && DeploymentSetting.respect_start_date?

      zone = (user || User.current)&.time_zone
      zone ? issue.start_date.in_time_zone(zone) : issue.start_date.to_time
    end

    private

    # the projects of the issues, whose deploy status is visible to the user (the permission) and that have environments
    def projects
      @projects ||= issues.map(&:project).uniq.select do |project|
        Array(permission).any? { |name| user.allowed_to?(name, project) } && environments_for(project).any?
      end
    end

    def compute
      projects_by_id = projects.index_by(&:id)
      issue_projects = issues.select { |issue| projects_by_id.key?(issue.project_id) }.to_h { |issue| [issue.id, issue.project_id] }
      rows           = changeset_rows(issue_projects.keys)
      return {} if rows.empty?

      repositories = Repository.where(id: rows.map(&:third).uniq).index_by(&:id)
      issues_by_id = issues.index_by(&:id)

      rows.group_by { |row| issue_projects[row.first] }.each_with_object({}) do |(project_id, project_rows), statuses|
        environments = environments_for(projects_by_id[project_id])
        targets      = targets_for(environments, project_rows.map(&:first).uniq.map { |issue_id| issues_by_id[issue_id] })
        covering     = covering_deployments(project_rows, environments, targets).
          merge(covering_refs(project_rows, repositories, environments, targets))

        code = code_for(projects_by_id[project_id])
        project_rows.group_by(&:first).each do |issue_id, issue_rows|
          statuses[issue_id] = result_for(issue_id, issue_rows.map(&:second).uniq, covering, environments, targets, code)
        end
      end
    end

    # The values of the environments resolved for the issues (the same target for all of them without placeholders).
    #
    # @return [Hash{String => Hash{Integer => Environments::Target, nil}}] target by environment key and issue id
    def targets_for(environments, issues)
      preload_placeholders(environments, issues)

      environments.to_h do |environment|
        static = environment.target(nil) unless environment.placeholders?
        [environment.key, issues.to_h { |issue| [issue.id, environment.placeholders? ? environment.target(issue) : static] }]
      end
    end

    # the associations of the placeholders (e.g. {%tracker.name%}) at once - no N+1
    def preload_placeholders(environments, issues)
      associations = Environments.placeholder_associations(environments)
      ActiveRecord::Associations::Preloader.new(records: issues, associations: associations).call if associations.any? && issues.any?
    end

    def result_for(issue_id, changeset_ids, covering, environments, targets, code)
      states = environments.map do |environment|
        target  = targets[environment.key][issue_id]
        covered = target ? changeset_ids.count { |changeset_id| covering.dig([environment.key, target], changeset_id).present? } : 0
        Environment.new(key: environment.key, label: environment.label, color: environment.color,
                        target: target&.text || environment.value, covered: covered, total: changeset_ids.size)
      end

      result = Result.new(changeset_count: changeset_ids.size, code: code, environments: states)
      last   = environments.last
      if result.live? && last.deployment?
        # all changesets are live, as soon as the last of them was deployed for the first time
        deployed = covering[[last.key, targets[last.key][issue_id]]]
        result.live_since = changeset_ids.map { |changeset_id| deployed[changeset_id].map(&:created_on).min }.max
      end
      result
    end

    # @return [Array<Array(String, Environments::Target)>] the distinct targets of the environments: [key, target]
    def distinct_targets(environments, targets)
      environments.flat_map { |environment| targets[environment.key].values.compact.uniq.map { |target| [environment.key, target] } }
    end

    # The changesets of the issues - with the plugin setting "respect_start_date" (DeploymentSetting.respect_start_date?)
    # only those committed on or after the start date of their issue (+counting_since+ - from midnight in the time
    # zone of the user): commits made before the work on the issue began do not count towards its pipeline. Issues
    # without a start date keep all of them.
    #
    # @return [Array<Array>] [issue_id, changeset_id, repository_id]
    def changeset_rows(issue_ids)
      return [] if issue_ids.empty?

      rows = Changeset.joins("INNER JOIN #{Changeset.table_name_prefix}changesets_issues#{Changeset.table_name_suffix} ci ON ci.changeset_id = #{Changeset.table_name}.id").
        where('ci.issue_id' => issue_ids).
        pluck(Arel.sql('ci.issue_id'), "#{Changeset.table_name}.id", "#{Changeset.table_name}.repository_id", "#{Changeset.table_name}.committed_on")
      return rows.map { |row| row.first(3) } unless DeploymentSetting.respect_start_date?

      starts = issues.to_h { |issue| [issue.id, self.class.counting_since(issue, user)] }
      rows.filter_map do |issue_id, changeset_id, repository_id, committed_on|
        start = starts[issue_id]
        [issue_id, changeset_id, repository_id] if start.nil? || (committed_on && committed_on >= start)
      end
    end

    # The successful deployments of the changesets by their stored changesets (DeploymentChangeset - the commit
    # range of each deployment, resolved once in the background, see Deployment#resolve_changesets!): one indexed
    # query, nothing is computed here. A deployment whose changesets are not resolved (yet) covers nothing - just
    # like one without a defined range (a missing boundary, see Deployment#changesets).
    #
    # @return [Hash{Array(String, Environments::Target) => Hash{Integer => Array<Deployment>}}] successful deployments
    #   by [environment key, target] and changeset id
    def covering_deployments(rows, environments, targets)
      deployment_environments = environments.select(&:deployment?)
      wanted = distinct_targets(deployment_environments, targets)
      covering = Hash.new { |hash, key| hash[key] = {} }
      return covering if wanted.empty?

      links = DeploymentChangeset.joins(:deployment).
        where(changeset_id: rows.map(&:second).uniq, ::Deployment.table_name => { result: ::Deployment::RESULT_SUCCESS })
      # dynamic values are matched in Ruby (wildcards, case-insensitive), literal ones by the database already
      if deployment_environments.none?(&:dynamic?)
        links = links.where(::Deployment.table_name => { environment: wanted.map { |_, target| target.text }.uniq })
      end
      links = links.pluck(:deployment_id, :changeset_id)
      return covering if links.empty?

      deployments = ::Deployment.where(id: links.map(&:first).uniq).
        select(:id, :repository_id, :environment, :created_on).index_by(&:id)
      # each target against the distinct environments (within the budget of the regular expressions)
      names       = deployments.values.map(&:environment).uniq
      matched     = wanted.index_with { |entry| budget.select(entry.last, names).to_set }
      matching    = deployments.transform_values { |deployment| wanted.select { |entry| matched[entry].include?(deployment.environment) } }

      links.each do |deployment_id, changeset_id|
        matching[deployment_id].each { |key| (covering[key][changeset_id] ||= []) << deployments[deployment_id] }
      end

      covering
    end

    # A changeset is part of a branch / tag environment, if it is an ancestor of any of the branch heads / tag commits
    # matching its target (one branch for a literal value, e.g. all feature branches for "feature/*").
    #
    # @return [Hash{Array(String, Environments::Target) => Hash{Integer => true}}] changesets part of the branches /
    #   tags by [environment key, target] and changeset id
    def covering_refs(rows, repositories, environments, targets)
      ref_environments = environments.select(&:ref?).index_by(&:key)
      wanted = distinct_targets(ref_environments.values, targets)
      return {} if wanted.empty?

      changeset_ids = rows.group_by(&:third).transform_values { |repository_rows| repository_rows.to_set(&:second) }

      wanted.to_h do |key, target|
        covered = {}
        changeset_ids.each do |repository_id, repository_changeset_ids|
          repository = repositories[repository_id]
          next unless repository && dag_available?(repository)

          environment = ref_environments[key]
          ref_ancestor_ids(repository, environment, target, ref_head_ids(repository, environment, target)).each do |changeset_id|
            covered[changeset_id] = true if repository_changeset_ids.include?(changeset_id)
          end
        end
        [[key, target], covered]
      end
    end

    # @return [Array<Integer>] the changeset ids of the heads of the branches / the commits of the tags matching the
    #   target (sorted - only the ones fetched into Redmine)
    def ref_head_ids(repository, environment, target)
      revisions = environment.tag? ? tag_revisions(repository) : branch_revisions(repository)
      matching  = budget.select(target, revisions.keys).map { |name| revisions[name] }.uniq
      ids       = ref_changeset_ids(repository, matching)
      matching.filter_map { |revision| ids[revision] }.uniq.sort
    end

    # The changeset ids of the revisions (once per repository and request): one query for all revisions not looked up
    # yet - not one per branch / tag.
    #
    # @return [Hash{String => Integer, nil}] changeset id by revision (nil: not fetched into Redmine yet)
    def ref_changeset_ids(repository, revisions)
      @ref_changeset_ids ||= Hash.new { |hash, key| hash[key] = {} }
      known   = @ref_changeset_ids[repository.id]
      missing = revisions.reject { |revision| known.key?(revision) }
      missing.each_slice(REVISION_BATCH) do |batch|
        found = Changeset.where(repository_id: repository.id, revision: batch).pluck(:revision, :id).to_h
        batch.each { |revision| known[revision] = found[revision] }
      end
      known
    end

    # The heads of the branches of the repository (<tt>git branch</tt> - see +ref_revisions+).
    #
    # @return [Hash{String => String}] revision of the branch head by branch name
    def branch_revisions(repository)
      ref_revisions(repository, 'branches') do
        Array(repository.branches).to_h { |branch| [branch.to_s, (branch.scmid.presence || branch.revision).to_s] }
      end
    end

    # The commits of the tags of the repository (Repository::Git#tag_revisions - see +ref_revisions+).
    #
    # @return [Hash{String => String}] revision of the commit by tag name
    def tag_revisions(repository)
      ref_revisions(repository, 'tags') do
        repository.respond_to?(:tag_revisions) ? repository.tag_revisions.to_h : {}
      end
    end

    # The branches / tags of the repository: read from git (the block) once per request at most, and cached across
    # the requests for REFS_EXPIRES_IN - by the heads Redmine fetched last (Repository::Git: extra_info "heads"), so
    # new commits are seen at once; a branch or tag without new commits within REFS_EXPIRES_IN. One cache entry per
    # repository and kind (replaced, not added). A git error (e.g. Redmine::Scm::Adapters::CommandFailed - a missing
    # repository or git binary) is logged and not cached: no branches / tags.
    #
    # @return [Hash{String => String}] revision by name
    def ref_revisions(repository, kind, &block)
      @ref_revisions ||= {}
      return @ref_revisions[[repository.id, kind]] if @ref_revisions.key?([repository.id, kind])

      @ref_revisions[[repository.id, kind]] =
        begin
          Rails.cache.fetch([CACHE_NAMESPACE, kind, repository.id], version: refs_version(repository),
                                                                     expires_in: REFS_EXPIRES_IN, &block)
        rescue StandardError => e
          Rails.logger.warn("RubysmartDeployment::DeployStatus: #{kind} of repository #{repository.id}: #{e.message}")
          {}
        end
    end

    # the version of the cached branches / tags: the heads of the last fetch of the repository
    def refs_version(repository)
      heads = (repository.extra_info || {})['heads']
      Digest::SHA256.hexdigest(Array(heads).map(&:to_s).sort.join(','))
    end

    # the parent DAG is usable: a git repository with populated changeset parents (once per repository and request)
    def dag_available?(repository)
      @dag_available ||= {}
      return @dag_available[repository.id] if @dag_available.key?(repository.id)

      @dag_available[repository.id] = CommitRange.dag_available?(repository)
    end

    # All ancestors of the heads of a branch / tag step (inclusive) - one recursive query (CommitRange.ancestors),
    # cached by the step and the repository with the heads as version: ONE entry per step and repository, replaced
    # when a branch moves on or a tag is added (not one more entry each time), dropped when unused for
    # CACHE_EXPIRES_IN.
    #
    # @return [Array<Integer>] the changeset ids
    def ref_ancestor_ids(repository, environment, target, head_ids)
      return [] if head_ids.empty?

      Rails.cache.fetch([CACHE_NAMESPACE, 'ancestors', repository.id, environment.type, target.text],
                        version: Digest::SHA256.hexdigest(head_ids.join(',')), expires_in: CACHE_EXPIRES_IN) do
        CommitRange.ancestors(head_ids)
      end
    end

    # the time budget of the regular expressions of the settings (one per deploy status, i.e. per request)
    def budget
      @budget ||= Environments::MatchBudget.new
    end
  end
end
