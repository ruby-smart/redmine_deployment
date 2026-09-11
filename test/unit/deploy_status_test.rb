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

    # c1 <- c2 <- c3 <- c4 <- c5 (linear history)
    @c1 = commit('c1', [], 10.days.ago)
    @c2 = commit('c2', [@c1], 9.days.ago)
    @c3 = commit('c3', [@c2], 8.days.ago)
    @c4 = commit('c4', [@c3], 7.days.ago)
    @c5 = commit('c5', [@c4], 6.days.ago)
  end

  def test_issue_without_changesets_has_no_status
    deploy('staging', from: nil, to: @c5)

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

  def test_deployments_before_the_commits_are_not_loaded
    link(Issue.find(1), @c4)
    deploy('production', from: nil, to: @c1, created_on: 30.days.ago)
    deploy('production', from: @c3, to: @c5)

    status   = status_for(Issue.find(1))
    computed = []
    status.define_singleton_method(:range_ids) do |to_id, from_id, &block|
      computed << to_id
      super(to_id, from_id, &block)
    end

    assert_equal %i[none reached], status[Issue.find(1)].environments.map(&:state)
    # only the range of the recent deployment (to: c5) is computed, not the one of the old deployment (to: c1)
    assert_equal [@c5.id], computed
  end

  def test_range_ids_equal_deployment_changesets
    # merge commit: c5 <- m -> side (side branches off c3)
    side  = commit('side', [@c3], 5.days.ago)
    merge = commit('merge', [@c5, side], 4.days.ago)

    deployments = [
      deploy('production', from: @c2, to: merge),
      deploy('production', from: nil, to: @c3),
      deploy('production', from: side, to: merge),
      deploy('production', from: @c5, to: @c3), # rollback
      deploy('production', from: 'unknown', to: @c4)
    ]
    service = DeployStatus.new([], user: @user, environments: @environments)

    deployments.each do |deployment|
      revisions = [@repository.find_changeset_by_name(deployment.to_revision), @repository.find_changeset_by_name(deployment.from_revision)]
      expected  = deployment.changesets.pluck(:id).sort
      actual    = service.send(:range_ids, revisions[0].id, revisions[1]&.id) { flunk 'no fallback expected' }.sort

      assert_equal expected, actual, "range of #{deployment.from_revision}..#{deployment.to_revision}"
    end
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
    deployment
  end
end
