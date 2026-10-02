# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class IssueDeploymentsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :repositories, :enabled_modules,
           :issues, :issue_statuses, :trackers, :enumerations,
           :projects_trackers, :roles, :members, :member_roles

  def setup
    @project    = Project.find(1)
    @user       = User.find(2)
    @repository = Repository::Git.create!(:project => @project, :url => '/tmp/repo.git')

    # Linear master history: A - B - C - D
    @a = create_changeset('a', 40.minutes.ago)
    @b = create_changeset('b', 30.minutes.ago, [@a])
    @c = create_changeset('c', 20.minutes.ago, [@b])
    @d = create_changeset('d', 10.minutes.ago, [@c])

    @issue = Issue.find(1)
  end

  def test_issue_deployments_returns_deployment_whose_range_contains_an_issue_changeset
    @issue.changesets << @c
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert_equal [deployment.id], @issue.deployments.map(&:id)
  end

  def test_issue_deployments_excludes_deployment_whose_range_does_not_contain_the_changeset
    @issue.changesets << @d
    # Range A..C does NOT include D.
    create_deployment(:from_revision => @a.revision, :to_revision => @c.revision)

    assert_empty @issue.deployments
  end

  def test_issue_without_changesets_has_no_deployments
    create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert_empty @issue.deployments
  end

  def test_issue_deployments_ignores_deployments_of_other_repositories
    other_repo = Repository::Git.create!(:project => Project.find(2), :url => '/tmp/other.git')
    @issue.changesets << @c
    Deployment.create!(
      :project => Project.find(2), :repository => other_repo, :author => @user,
      :result => Deployment::RESULT_SUCCESS, :from_revision => @a.revision, :to_revision => @d.revision
    )

    assert_empty @issue.deployments
  end

  # The deployments are found by their stored changesets (DeploymentChangeset): one indexed query, no walk over
  # the commit graph per candidate deployment - however many deployments the repository has.
  def test_issue_deployments_is_a_single_query
    @issue.changesets << @c
    5.times { create_deployment(:from_revision => @a.revision, :to_revision => @d.revision) }
    5.times { create_deployment(:from_revision => @c.revision, :to_revision => @d.revision) }
    RedmineDeployment::CommitRange.expects(:ids).never

    queries = count_queries { assert_equal 5, @issue.deployments.to_a.size }

    assert_equal 1, queries
  end

  # Logged before Redmine fetched its commits (the usual order of events): the deployment is listed as soon as it
  # is resolved - after the fetch, or by the rake task.
  def test_issue_deployments_includes_a_deployment_resolved_later
    deployment = create_deployment(:from_revision => @c.revision, :to_revision => 'e')
    assert_empty @issue.deployments

    e = create_changeset('e', 5.minutes.ago, [@d])
    @issue.changesets << e
    assert_empty @issue.deployments, 'not resolved yet'

    deployment.resolve_changesets!

    assert_equal [deployment.id], @issue.deployments.map(&:id)
  end

  def test_issue_deployments_orders_newest_first
    @issue.changesets << @c
    older = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision,
                              :created_on => 2.days.ago)
    newer = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision,
                              :created_on => 1.hour.ago)

    assert_equal [newer.id, older.id], @issue.deployments.map(&:id)
  end

  private

  def create_changeset(name, committed_on, parents = [])
    Changeset.create!(
      :repository   => @repository,
      :revision     => name,
      :scmid        => name,
      :committed_on => committed_on,
      :committer    => 'tester',
      :parents      => parents
    )
  end

  def create_deployment(attrs = {})
    Deployment.create!({
      :project    => @project,
      :repository => @repository,
      :author     => @user,
      :result     => Deployment::RESULT_SUCCESS
    }.merge(attrs))
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
