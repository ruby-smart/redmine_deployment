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

  def test_issue_deployments_excludes_deployments_created_before_the_issue
    @issue.changesets << @c
    # Range contains the issue's changeset, but the deploy happened before the issue existed,
    # so it cannot actually have deployed this issue's work and is pruned without a DAG walk.
    create_deployment(:from_revision => @a.revision, :to_revision => @d.revision,
                      :created_on => @issue.created_on - 1.hour)

    assert_empty @issue.deployments
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
end
