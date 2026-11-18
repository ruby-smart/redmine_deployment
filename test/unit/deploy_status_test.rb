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

  def test_commit_range_ids_equal_deployment_changesets
    # merge commit: c5 <- m -> side (side branches off c3)
    side  = commit('side', [@c3], 5.days.ago)
    merge = commit('merge', [@c5, side], 4.days.ago)

    deployments = [
      deploy('production', from: @c2, to: merge),
      deploy('production', from: side, to: merge),
      deploy('production', from: @c5, to: @c3) # rollback
    ]

    deployments.each do |deployment|
      revisions = [@repository.find_changeset_by_name(deployment.to_revision), @repository.find_changeset_by_name(deployment.from_revision)]
      expected  = deployment.changesets.pluck(:id).sort
      actual    = RedmineDeployment::CommitRange.ids(revisions[0].id, revisions[1].id).sort

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

  def test_branch_regexp
    use_environments(['branch', '/^(feature|bugfix)\/{%issue.id%}-/i', 'Feature'], ['branch', '/^(main|master)$/', 'Main'])
    branches('Bugfix/1-login' => @c3, 'feature/12-logout' => @c5, 'master' => @c2)
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    # issue 1: its own bugfix branch (case-insensitive), not merged into master
    assert_equal %i[reached none], status[Issue.find(1)].environments.map(&:state)
    assert_equal ['/^(feature|bugfix)\/1-/i', '/^(main|master)$/'], status[Issue.find(1)].environments.map(&:target)
    # issue 2: feature/12-logout is no branch of issue 2
    assert_equal %i[none none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_deployment_regexp
    use_environments(['deployment', '/^(staging|qa)-/', 'Stage'], ['deployment', '/^prod(uction)?$/', 'Live'])
    deploy('qa-1', from: @c1, to: @c3)
    deploy('production', from: @c0, to: @c3)
    deploy('prod-eu', from: @c0, to: @c5) # does not match /^prod(uction)?$/
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached reached], status[Issue.find(1)].environments.map(&:state)
    assert status[Issue.find(1)].live_since
    assert_equal %i[none none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_tag_environment
    use_environments(%w[branch main Main], %w[tag v1.0 Release])
    branches('main' => @c5)
    tags('v1.0' => @c3, 'v0.9' => @c2)
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c4)

    status = status_for(Issue.find(1), Issue.find(2))

    # c3 is the commit of v1.0, c4 is newer
    assert_equal %i[reached reached], status[Issue.find(1)].environments.map(&:state)
    assert_nil status[Issue.find(1)].live_since
    assert_equal %i[reached none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_tag_regexp_matches_any_tag
    use_environments(['tag', '/^v\\d+\\.\\d+$/', 'Release'])
    tags('v1.0' => @c2, 'v1.1' => @c4, 'v1.2-rc1' => @c5)
    link(Issue.find(1), @c3, @c4)
    link(Issue.find(2), @c5)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal %i[reached], status[Issue.find(1)].environments.map(&:state)
    # a release candidate is no release
    assert_equal %i[none], status[Issue.find(2)].environments.map(&:state)
  end

  def test_tag_partial
    use_environments(%w[tag v1.* Release])
    tags('v1.0' => @c3)
    link(Issue.find(1), @c3, @c5)

    assert_equal %i[partial], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_tags_and_branches_of_the_same_name_are_not_mixed
    use_environments(%w[branch release Branch], %w[tag release Tag])
    branches('release' => @c5)
    tags('release' => @c2)
    link(Issue.find(1), @c3)

    assert_equal %i[reached none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_tag_environment_needs_no_deployments
    use_environments(%w[tag v1 Release])
    tags('v1' => @c3)
    link(Issue.find(1), @c3)

    service = DeployStatus.new([Issue.find(1)], user: @user, environments: @environments)

    assert service.enabled?
    assert_equal %i[reached], service[Issue.find(1)].environments.map(&:state)
  end

  def test_tags_are_read_once_per_repository_and_errors_are_ignored
    use_environments(%w[tag v1 V1], %w[tag v2 V2])
    Repository::Git.any_instance.expects(:tag_revisions).once.returns('v1' => @c3.revision, 'v2' => 'f' * 40)
    link(Issue.find(1), @c3)

    # v2: its commit is not fetched into Redmine
    assert_equal %i[reached none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)

    Repository::Git.any_instance.unstub(:tag_revisions)
    Repository::Git.any_instance.stubs(:tag_revisions).raises(Redmine::Scm::Adapters::CommandFailed, 'git failed')
    assert_equal %i[none none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
  end

  def test_ancestors_of_several_heads
    side = commit('side', [@c2], 5.days.ago)
    expected = (RedmineDeployment::CommitRange.ids(@c3.id) | RedmineDeployment::CommitRange.ids(side.id)).sort

    assert_equal expected, RedmineDeployment::CommitRange.ancestors([@c3.id, side.id, @c3.id]).sort
    assert_equal [@c0, @c1, @c2, side].map(&:id).sort, RedmineDeployment::CommitRange.ancestors([side.id]).sort
    assert_equal [], RedmineDeployment::CommitRange.ancestors([])

    # without recursive queries: the walk in Ruby
    RedmineDeployment::CommitRange.stubs(:sql_ancestors).raises(ActiveRecord::StatementInvalid, 'no recursive CTE')
    assert_equal expected, RedmineDeployment::CommitRange.ancestors([@c3.id, side.id]).sort
  end

  def test_matching_tags_cost_the_same_whatever_their_number
    use_environments(['tag', '/^v/', 'Release'])
    link(Issue.find(1), @c3)
    link(Issue.find(2), @c5)
    commits = [@c1, @c2, @c3]
    ancestors_of_c3 = RedmineDeployment::CommitRange.ids(@c3.id)

    # the first run loads settings, roles etc. once
    runs = [3, 3, 30].map do |count|
      # the tags on c1..c3 - and some whose commits are not fetched into Redmine
      revisions = (1..count).to_h { |n| ["v#{n}", n % 4 == 0 ? format('%040x', n) : commits[n % 3].revision] }
      Repository::Git.any_instance.stubs(:tag_revisions).returns(revisions)
      RedmineDeployment::CommitRange.expects(:ancestors).once.returns(ancestors_of_c3)

      queries = 0
      counter = ->(*, payload) { queries += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      status  = ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { status_for(Issue.find(1), Issue.find(2)).statuses }
      RedmineDeployment::CommitRange.unstub(:ancestors)

      [queries, status.transform_values { |result| result.environments.map(&:state) }]
    end

    assert_equal({ 1 => %i[reached], 2 => %i[none] }, runs.second.last)
    # the same queries for 30 tags as for 3
    assert_equal runs.second, runs.last
  end

  # the branches / tags are read from git once per REFS_EXPIRES_IN - at once again, when the repository fetched new
  # commits (its heads)
  def test_branches_are_cached_across_requests_until_the_repository_fetched_new_commits
    use_environments(%w[branch develop Develop])
    link(Issue.find(1), @c4)

    with_memory_cache do
      branches('develop' => @c3)
      Repository::Git.any_instance.expects(:branches).once.returns(@branches)
      2.times { assert_equal %i[none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state) }

      fetched('develop' => @c5)
      Repository::Git.any_instance.expects(:branches).once.returns(@branches)
      2.times { assert_equal %i[reached], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state) }
    end
  end

  def test_tags_are_cached_across_requests_and_git_errors_are_not
    use_environments(%w[tag v1 V1])
    link(Issue.find(1), @c3)

    with_memory_cache do
      Repository::Git.any_instance.expects(:tag_revisions).twice.raises(Redmine::Scm::Adapters::CommandFailed, 'git failed')
      2.times { assert_equal %i[none], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state) }

      Repository::Git.any_instance.expects(:tag_revisions).once.returns('v1' => @c3.revision)
      2.times { assert_equal %i[reached], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state) }
    end
  end

  # one cache entry per step and repository: replaced when the heads change, not one more each time
  def test_the_ancestors_of_a_step_are_one_cache_entry
    use_environments(['branch', 'feature/*', 'Feature'], ['tag', '/^v/', 'Release'])
    link(Issue.find(1), @c3)

    with_memory_cache do |cache|
      [@c3, @c4, @c5].each do |head|
        fetched('feature/a' => head, 'feature/b' => @c2)
        tags('v1' => @c1, 'v2' => head)
        assert_equal %i[reached reached], status_for(Issue.find(1))[Issue.find(1)].environments.map(&:state)
      end

      keys = cache.instance_variable_get(:@data).keys.grep(/ancestors/)
      assert_equal 2, keys.size, keys.inspect
      assert keys.all? { |key| cache.send(:read_entry, key).expires_at }, 'the entries expire'
    end
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

  def test_changesets_before_the_start_date_count_by_default
    link(Issue.find(1), @c2, @c3)
    deploy('staging', from: @c1, to: @c3)
    Issue.find(1).update_column(:start_date, @c3.committed_on.localtime.to_date)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_not DeploymentSetting.respect_start_date?
    assert_equal 2, result.changeset_count
  end

  def test_respect_start_date_ignores_the_changesets_before_the_start_date
    Setting.plugin_redmine_deployment = { 'respect_start_date' => '1' }
    link(Issue.find(1), @c2, @c3, @c4)
    deploy('staging', from: @c2, to: @c3)
    # c2 was committed the day before, c3 on the start date (later that day) - it counts
    Issue.find(1).update_column(:start_date, @c3.committed_on.localtime.to_date)

    result = status_for(Issue.find(1))[Issue.find(1)]

    assert_equal 2, result.changeset_count
    assert_equal [[1, 2], [0, 2]], result.environments.map { |environment| [environment.covered, environment.total] }
    assert_equal [:partial, :none], result.environments.map(&:state)
  end

  def test_respect_start_date_without_changesets_since_the_start_date
    Setting.plugin_redmine_deployment = { 'respect_start_date' => '1' }
    link(Issue.find(1), @c2, @c3)
    deploy('staging', from: @c1, to: @c3)
    Issue.find(1).update_column(:start_date, Date.current)

    assert_nil status_for(Issue.find(1))[Issue.find(1)]
  end

  # from midnight in the time zone of the user - the server's without one
  def test_respect_start_date_from_midnight_in_the_time_zone_of_the_user
    Setting.plugin_redmine_deployment = { 'respect_start_date' => '1' }
    tokyo = ActiveSupport::TimeZone['Tokyo']
    start = tokyo.now.to_date - 1
    # 01:00 in Tokyo on the start date - the day before in UTC and in Hawaii
    late = commit('late', [@c5], tokyo.local(start.year, start.month, start.day, 1))
    link(Issue.find(1), @c3, late)
    deploy('staging', from: @c1, to: late)
    Issue.find(1).update_column(:start_date, start)

    assert_equal tokyo.local(start.year, start.month, start.day), DeployStatus.counting_since(Issue.find(1), user_in('Tokyo'))
    assert_equal start.to_time, DeployStatus.counting_since(Issue.find(1), user_in(''))
    assert_equal 1, DeployStatus.new([Issue.find(1)], user: user_in('Tokyo'), environments: @environments)[Issue.find(1)].changeset_count
    assert_nil DeployStatus.new([Issue.find(1)], user: user_in('Hawaii'), environments: @environments)[Issue.find(1)]

    Setting.plugin_redmine_deployment = { 'respect_start_date' => '0' }
    assert_nil DeployStatus.counting_since(Issue.find(1), user_in('Tokyo'))
  end

  def test_respect_start_date_counts_all_changesets_of_an_issue_without_start_date
    Setting.plugin_redmine_deployment = { 'respect_start_date' => '1' }
    link(Issue.find(1), @c2, @c3)
    link(Issue.find(2), @c2, @c3)
    deploy('staging', from: @c1, to: @c3)
    Issue.find(1).update_column(:start_date, nil)
    Issue.find(2).update_column(:start_date, @c3.committed_on.localtime.to_date)

    status = status_for(Issue.find(1), Issue.find(2))

    assert_equal 2, status[Issue.find(1)].changeset_count
    assert_equal 1, status[Issue.find(2)].changeset_count
    assert_equal :reached, status[Issue.find(2)].environments.first.state
  end

  private

  def env_states(result)
    result.environments.map { |environment| [environment.label, environment.color, environment.state] }
  end

  def use_environments(*environments)
    @environments = environments.map { |type, value, label| Environment.new(type, value, label) }
  end

  # the user (jsmith) with a time zone ('': none)
  def user_in(zone)
    @user.pref.update!(time_zone: zone)
    User.find(@user.id)
  end

  # stubs the branches and records them as fetched (the heads of the repository change - see DeployStatus#refs_version)
  def fetched(heads)
    branches(heads)
    @repository.merge_extra_info('heads' => heads.values.map(&:revision))
    @repository.save!
  end

  # a cache that keeps its entries (the test environment has none)
  def with_memory_cache
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield Rails.cache
  ensure
    Rails.cache = cache
  end

  # stubs the tags of the git repositories: name => changeset
  def tags(commits)
    Repository::Git.any_instance.stubs(:tag_revisions).returns(commits.transform_values(&:revision))
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
