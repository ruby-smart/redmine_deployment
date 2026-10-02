# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class DeployStatusTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :repositories,
           :trackers, :projects_trackers, :issue_statuses, :issues, :enumerations

  Environment = RedmineDeployment::Environments::Environment
  DeployStatus = RedmineDeployment::DeployStatus

  def setup
    Rails.cache.clear
    Setting.clear_cache
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'deployment')
    Role.find(1).add_permission!(:view_deployments)
    @user = User.find(2) # jsmith, manager of project 1

    @repository   = Repository::Git.create!(project: @project, identifier: 'taskboard', url: '/tmp/taskboard.git')
    @environments = [Environment.new('deployment', 'staging', 'Staging'), Environment.new('deployment', 'production', 'Live')]

    # c0 <- c1 <- c2 <- c3 <- c4 <- c5 (linear history)
    # c0 is the root commit and is never linked to an issue: it only serves as the lower bound of deployments
    # that are meant to cover "everything" - a deployment needs both boundaries (see Deployment#changesets).
    @c0 = commit('c0', [], 11.days.ago)
    @c1 = commit('c1', [@c0], 10.days.ago)
    @c2 = commit('c2', [@c1], 9.days.ago)
    @c3 = commit('c3', [@c2], 8.days.ago)
    @c4 = commit('c4', [@c3], 7.days.ago)
    @c5 = commit('c5', [@c4], 6.days.ago)
  end

  def test_issue_without_changesets_has_no_status
    deploy('staging', from: @c0, to: @c5)

    status = status_for(Issue.find(1))

    assert_nil status[Issue.find(1)]
    assert status.enabled?
  end

  def test_code_only
    link(Issue.find(1), @c5)
    deploy('staging', from: @c1, to: @c2)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal 1, result.changeset_count
    assert_equal 0, result.level
    assert_equal 0, result.top
    assert_not result.partial?
    assert_not result.live?
  end

  def test_only_staging
    link(Issue.find(1), @c2, @c3)
    deploy('staging', from: @c1, to: @c3)
    deploy('production', from: @c1, to: @c1)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal 1, result.level
    assert_equal %i[reached none], result.environments.map(&:state)
    assert_not result.live?
    assert_nil result.live_since
  end

  def test_live
    link(Issue.find(1), @c2, @c3)
    deploy('staging', from: @c1, to: @c3, created_on: 3.days.ago)
    early = deploy('production', from: @c1, to: @c2, created_on: 2.days.ago)
    late  = deploy('production', from: @c2, to: @c4, created_on: 1.day.ago)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert result.live?
    assert_equal 2, result.level
    # live, as soon as the last changeset (c3) reached production
    assert_equal late.created_on.to_i, result.live_since.to_i
    assert_operator early.created_on, :<, result.live_since
  end

  def test_partial_if_a_newer_commit_is_not_deployed
    link(Issue.find(1), @c2, @c5)
    deploy('staging', from: @c1, to: @c3)
    deploy('production', from: @c1, to: @c3)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal %i[partial partial], result.environments.map(&:state)
    assert_equal 0, result.level
    assert_equal 2, result.top
    assert result.partial?
    assert_not result.live?
    assert_equal 'Live', result.top_environment.label
  end

  def test_failed_deployments_are_ignored
    link(Issue.find(1), @c3)
    deploy('staging', from: @c1, to: @c4)
    deploy('production', from: @c1, to: @c4, result: Deployment::RESULT_FAIL)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal %i[reached none], result.environments.map(&:state)
    assert_not result.live?
  end

  # nothing of a failed deployment counts towards the pipeline - not even its existence
  def test_a_project_with_failed_deployments_only_has_no_deploy_status
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c3, result: Deployment::RESULT_FAIL)

    # environments of the deployment type only: without a successful deployment there is nothing to show
    status = DeployStatus.new([Issue.find(1)], user: @user,
                              environments: @environments.select(&:deployment?))

    assert_not status.enabled?
    assert_nil status[Issue.find(1)]

    # the successful one brings the pipeline back
    deploy('production', from: @c1, to: @c3)
    status = DeployStatus.new([Issue.find(1)], user: @user, environments: @environments.select(&:deployment?))

    assert status.enabled?
  end

  def test_delta_ranges_like_redmine_deployment
    # c2 was deployed with the failed deployment only - the next successful one starts after it (from: c3)
    link(Issue.find(1), @c2)
    link(Issue.find(2), @c4)
    deploy('production', from: @c1, to: @c3, result: Deployment::RESULT_FAIL)
    deploy('production', from: @c3, to: @c5)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[none none], status[Issue.find(1)].environments.map(&:state)
    assert_equal %i[none reached], status[Issue.find(2)].environments.map(&:state)
  end

  # the changesets of the deployments are stored (DeploymentChangeset) - the status reads them, it never computes a
  # commit range of a deployment, however many deployments the repository has
  def test_deployment_ranges_are_not_computed
    link(Issue.find(1), @c4)
    deploy('production', from: @c0, to: @c1, created_on: 30.days.ago)
    deploy('production', from: @c3, to: @c5)

    queries = status_queries { |status| assert_equal %i[none reached], status[Issue.find(1)].environments.map(&:state) }

    # ten times the deployments: not a single query more (the links of the changesets and the deployments at once)
    10.times { |i| deploy('production', from: @c0, to: @c1, created_on: (31 + i).days.ago) }
    10.times { deploy('production', from: @c3, to: @c5) }
    scaled = status_queries { |status| assert_equal %i[none reached], status[Issue.find(1)].environments.map(&:state) }

    assert_operator scaled, :<=, queries, "#{scaled} queries for 22 deployments, #{queries} for 2"
  end

  # the queries of the deploy status of issue 1 - and not a single commit range computed meanwhile
  def status_queries
    RedmineDeployment::CommitRange.stubs(:ids).raises('a commit range was computed for the deploy status')
    status = status_for(Issue.find(1))
    count_queries { yield status }
  ensure
    RedmineDeployment::CommitRange.unstub(:ids)
  end

  # Logged before its commits were fetched into Redmine, a deployment stays pending and covers nothing until it is
  # resolved (after the fetch of the repository, or by the rake task)
  def test_unresolved_deployment_covers_nothing_until_it_is_resolved
    link(Issue.find(1), @c5)
    deployment = deploy('production', from: @c4, to: 'c6')
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason

    assert_equal %i[none none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)

    commit('c6', [@c5], 5.days.ago)
    deployment.resolve_changesets!

    assert_equal %i[none reached], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_range_ids_equal_deployment_changesets
    # merge commit: c5 <- m -> side (side branches off c3)
    side  = commit('side', [@c3], 5.days.ago)
    merge = commit('merge', [@c5, side], 4.days.ago)

    deployments = [
      deploy('production', from: @c2, to: merge),
      deploy('production', from: side, to: merge),
      deploy('production', from: @c5, to: @c3) # rollback
    ]
    service = DeployStatus.new([], user: @user, environments: @environments)

    deployments.each do |deployment|
      revisions = [@repository.find_changeset_by_name(deployment.to_revision), @repository.find_changeset_by_name(deployment.from_revision)]
      expected  = deployment.changesets.pluck(:id).sort
      actual    = service.send(:range_ids, revisions[0].id, revisions[1].id).sort

      assert_equal expected, actual, "range of #{deployment.from_revision}..#{deployment.to_revision}"
    end
  end

  # A deployment missing a boundary has no commit range at all (see Deployment#changesets) - it must not be
  # treated as "everything since the root commit" and mark every issue of the repository as deployed.
  def test_deployment_without_resolvable_from_revision_covers_nothing
    link(Issue.find(1), @c2, @c3)
    deploy('production', from: nil, to: @c5)
    deploy('production', from: 'unknown', to: @c5)
    deploy('production', from: '0' * 40, to: @c5)

    assert_equal %i[none none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  # Git's null revision must not be looked up at all: Repository::Git#find_changeset_by_name falls back
  # to an "scmid LIKE '<name>%'" prefix match, so a short "000000" resolves to any commit whose id starts
  # with zeros. Such a bogus lower bound prunes nothing, so the range would swallow the whole history.
  def test_null_from_revision_is_not_prefix_matched_to_a_zero_leading_commit
    stray = commit('000000stray', [], 12.days.ago) # off to the side, not an ancestor of c5
    link(Issue.find(1), @c2)
    deploy('production', from: '000000', to: @c5)

    assert_equal stray, @repository.find_changeset_by_name('000000'),
                 'guard: the repository itself would resolve the placeholder to this commit'
    assert_equal %i[none none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_branch_environment
    use_environments(%w[branch develop Develop], %w[deployment production Live])
    branches('develop' => @c3, 'main' => @c5)
    link(Issue.find(1), @c2, @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached none], status[Issue.find(1)].environments.map(&:state)
    assert_equal 1, status[Issue.find(1)].level
    assert_equal 'Develop', status[Issue.find(1)].top_environment.label
    assert_equal %i[none none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_branch_environment_partial
    use_environments(%w[branch develop Develop])
    branches('develop' => @c2)
    link(Issue.find(1), @c2, @c3)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal %i[partial], result.environments.map(&:state)
    assert result.partial?
  end

  def test_branch_environment_with_merged_side_branch
    side  = commit('side', [@c3], 5.days.ago)
    other = commit('other', [@c3], 5.days.ago)
    merge = commit('merge', [@c5, side], 4.days.ago)
    use_environments(%w[branch main Main])
    branches('main' => merge, 'feature' => other)
    link(Issue.find(1), side)
    link(Issue.find(2), other)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached], status[Issue.find(1)].environments.map(&:state)
    assert_equal %i[none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_branch_as_last_environment_is_live_without_live_since
    use_environments(%w[deployment staging Staging], %w[branch main Main])
    branches('main' => @c5)
    deploy('staging', from: @c1, to: @c4)
    link(Issue.find(1), @c3)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert result.live?
    assert_nil result.live_since
  end

  def test_branch_environment_needs_no_deployments
    use_environments(%w[branch main Main])
    branches('main' => @c5)
    link(Issue.find(1), @c3)

    status = status_for(Issue.find(1))

    assert status.enabled?
    assert status[Issue.find(1)].live?
  end

  def test_unknown_branch_or_unfetched_head
    use_environments(%w[branch develop Develop], %w[branch main Main])
    branch = Redmine::Scm::Adapters::GitAdapter::GitBranch.new('main')
    branch.revision = branch.scmid = 'f' * 40 # not fetched into Redmine
    Repository::Git.any_instance.stubs(:branches).returns([branch])
    link(Issue.find(1), @c3)

    assert_equal %i[none none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_git_errors_are_ignored
    use_environments(%w[branch main Main], %w[deployment production Live])
    Repository::Git.any_instance.stubs(:branches).raises(Redmine::Scm::Adapters::CommandFailed, 'git failed')
    deploy('production', from: @c1, to: @c4)
    link(Issue.find(1), @c3)

    assert_equal %i[none reached], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_branches_are_read_once_per_repository
    use_environments(%w[branch develop Develop], %w[branch main Main])
    branches('develop' => @c3, 'main' => @c5)
    Repository::Git.any_instance.expects(:branches).once.returns(@branches)
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached reached], status[Issue.find(1)].environments.map(&:state)
    assert_equal %i[none reached], status[Issue.find(2)].environments.map(&:state)
  end

  def test_branch_wildcard
    use_environments(%w[branch feature/* Feature], %w[branch main Main])
    side = commit('side', [@c2], 5.days.ago)
    branches('feature/a' => @c3, 'feature/b' => side, 'main' => @c2)
    link(Issue.find(1), @c3, side)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    # merged into any feature branch
    assert_equal %i[reached none], status[Issue.find(1)].environments.map(&:state)
    assert_equal 'feature/*', status[Issue.find(1)].environments.first.target
    assert_equal %i[none none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_branch_placeholders
    use_environments(['branch', 'feature/{%issue.id%}-*', 'Feature'], ['branch', '{%tracker.name%}/*', 'Tracker'])
    branches('feature/1-login' => @c3, 'feature/2-logout' => @c5, 'bug/x' => @c2)
    link(Issue.find(1), @c3) # Bug
    link(Issue.find(2), @c4) # Feature request

    status = status_for(Issue.find(1), Issue.find(2))

    # issue 1: its own feature branch, the branches of its tracker (case-insensitive) don't have c3
    assert_equal %i[reached none], status[Issue.find(1)].environments.map(&:state)
    assert_equal ['feature/1-*', 'Bug/*'], status[Issue.find(1)].environments.map(&:target)
    # issue 2: c4 is part of feature/2-logout only
    assert_equal %i[reached none], status[Issue.find(2)].environments.map(&:state)
    assert_equal 'feature/2-*', status[Issue.find(2)].environments.first.target
  end

  def test_deployment_wildcards_and_placeholders
    use_environments(['deployment', 'review-{%issue.id%}', 'Review'], ['deployment', 'prod-*', 'Live'])
    deploy('review-1', from: @c1, to: @c3)
    deploy('review-2', from: @c1, to: @c5)
    deploy('prod-eu', from: @c0, to: @c3)
    deploy('production', from: @c0, to: @c5) # does not match prod-*
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached reached], status[Issue.find(1)].environments.map(&:state)
    assert status[Issue.find(1)].live_since
    assert_equal %i[reached none], status[Issue.find(2)].environments.map(&:state)
    assert_equal ['review-2', 'prod-*'], status[Issue.find(2)].environments.map(&:target)
  end

  def test_unresolvable_placeholder_is_not_reached
    use_environments(['branch', 'review/{%assigned_to.login%}', 'Review'])
    branches('review/jsmith' => @c5)
    issue = Issue.find(1)
    issue.update_columns(assigned_to_id: nil)
    link(issue, @c3)

    result = status_for(issue.reload)[issue]

    assert_equal %i[none], result.environments.map(&:state)
    assert_equal 'review/{%assigned_to.login%}', result.environments.first.target
  end

  def test_disabled_without_environments
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c3)

    status = DeployStatus.new([Issue.find(1)], user: @user, environments: [])

    assert_not status.enabled?
    assert_empty status.statuses
    assert_nil status[Issue.find(1)]
  end

  def test_disabled_without_the_module
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c3)
    @project.enabled_modules.where(name: 'deployment').delete_all

    assert_not status_for(Issue.find(1).reload).enabled?
  end

  def test_the_environments_of_each_project
    # project 1: its own environments, project 3: the central ones
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | staging | Staging
deployment | production | Live" }
    DeploymentSetting.update_project(@project, 'custom' => '1', 'environments' => "deployment | production | Production | red")
    EnabledModule.create!(project: Project.find(3), name: 'deployment')
    link(Issue.find(1), @c2)
    link(Issue.find(5), @c2)
    deploy('staging', from: @c1, to: @c3)
    deploy('production', from: @c1, to: @c2)

    status = DeployStatus.new([Issue.find(1), Issue.find(5)], user: User.find(1))

    assert_equal [['Production', '#c93c3c', :reached]], env_states(status[Issue.find(1)])
    assert_equal [['Staging', '#2f6db5', :reached], ['Live', '#2f9e44', :reached]], env_states(status[Issue.find(5)])
    assert status[Issue.find(1)].live?
  end

  def test_the_central_environments_by_default
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | production | Live" }
    DeploymentSetting.update_project(@project, 'custom' => '0', 'environments' => "deployment | staging | Staging")
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c2)

    status = DeployStatus.new([Issue.find(1)], user: @user)

    assert_equal [['Live', '#2f9e44', :reached]], env_states(status[Issue.find(1)])
  end

  def test_disabled_without_the_permission
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c3)
    Role.find(1).remove_permission!(:view_deployments)

    assert_not status_for(Issue.find(1)).enabled?
  end

  # the issue page and the issue query columns ask for the permission of the indicator (not the taskboard)
  def test_the_permission_to_view_the_indicator
    link(Issue.find(1), @c2)
    deploy('production', from: @c1, to: @c3)
    indicator = ->(permission) { DeployStatus.new([Issue.find(1)], user: @user, permission: permission, environments: @environments) }

    assert_not indicator.call(:view_deployment_indicator).enabled?
    assert indicator.call([:view_deployments, :view_deployment_indicator]).enabled?

    Role.find(1).add_permission!(:view_deployment_indicator)
    Role.find(1).remove_permission!(:view_deployments)
    @user.reload # the roles of a user are memoized

    assert indicator.call(:view_deployment_indicator).enabled?
    assert indicator.call([:view_deployments, :view_deployment_indicator]).enabled?
    assert_not status_for(Issue.find(1)).enabled?
  end

  def test_disabled_without_deployments
    link(Issue.find(1), @c2)

    assert_not status_for(Issue.find(1)).enabled?
  end

  def teardown
    Setting.clear_cache
  end

  private

  def env_states(result)
    result.environments.map { |environment| [environment.label, environment.color, environment.state] }
  end

  def use_environments(*environments)
    @environments = environments.map { |type, value, label| Environment.new(type, value, label) }
  end

  # stubs the branches of the git repositories: name => head changeset
  def branches(heads)
    @branches = heads.map do |name, changeset|
      branch = Redmine::Scm::Adapters::GitAdapter::GitBranch.new(name)
      branch.revision = branch.scmid = changeset.revision
      branch
    end
    Repository::Git.any_instance.stubs(:branches).returns(@branches)
  end

  def status_for(*issues)
    DeployStatus.new(issues, user: @user, environments: @environments)
  end

  def commit(name, parents, committed_on)
    Changeset.create!(repository: @repository, revision: name, scmid: name, committed_on: committed_on,
                      committer: 'tester', parents: parents)
  end

  def link(issue, *changesets)
    changesets.each { |changeset| issue.changesets << changeset }
  end

  def deploy(environment, from:, to:, result: Deployment::RESULT_SUCCESS, created_on: nil)
    revision = ->(value) { value.respond_to?(:revision) ? value.revision : value }
    deployment = Deployment.create!(project: @project, repository: @repository, author: User.find(1),
                                    environment: environment, result: result,
                                    from_revision: revision.call(from), to_revision: revision.call(to))
    deployment.update_columns(created_on: created_on) if created_on
    # the changesets are resolved by ResolveDeploymentChangesetsJob (inline here) on another instance
    deployment.reload
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
