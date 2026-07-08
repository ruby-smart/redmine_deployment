# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class DeploymentTest < ActiveSupport::TestCase
  fixtures :projects, :users, :repositories, :enabled_modules

  def setup
    @project = Project.find(1)
    @user    = User.find(2)
    @repository = Repository::Git.create!(
      :project => @project,
      :url     => '/tmp/does-not-need-to-exist.git'
    )

    # Build a commit DAG:
    #
    #   A - B - C ------- D   (master, deployed)
    #        \           /
    #         X - Y  (side branch, committed between C and D in wall-clock time
    #                 but NEVER merged into D)
    #
    # X and Y fall inside the A..D commit-time window, so the old timestamp-based
    # selection wrongly included them. The DAG walk must exclude them.
    @a = create_changeset('a', 1.hour.ago)
    @b = create_changeset('b', 50.minutes.ago, [@a])
    @c = create_changeset('c', 40.minutes.ago, [@b])
    @x = create_changeset('x', 30.minutes.ago, [@b])
    @y = create_changeset('y', 20.minutes.ago, [@x])
    @d = create_changeset('d', 10.minutes.ago, [@c])
  end

  def test_changesets_returns_only_commits_in_the_from_to_range
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert_equal [@b, @c, @d].map(&:id).sort, deployment.changesets.pluck(:id).sort
    assert_nil deployment.changesets_unavailable_reason
  end

  def test_changesets_excludes_unmerged_side_branch_in_time_window
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    ids = deployment.changesets.pluck(:id)
    assert_not_includes ids, @x.id, 'unmerged side-branch commit must be excluded'
    assert_not_includes ids, @y.id, 'unmerged side-branch commit must be excluded'

    # Guard: the side-branch commits ARE inside the naive commit-time window, proving the
    # regression this fix addresses would otherwise include them.
    assert @x.committed_on > @a.committed_on
    assert @x.committed_on < @d.committed_on
  end

  def test_changesets_excludes_the_from_revision_itself
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert_not_includes deployment.changesets.pluck(:id), @a.id
  end

  def test_changesets_counts_merge_diamond_once
    # Merge M brings the side branch back in: D's history reaches B via two paths (C and Y).
    merge = create_changeset('m', 5.minutes.ago, [@d, @y])
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => merge.revision)

    ids = deployment.changesets.pluck(:id)
    assert_equal ids, ids.uniq, 'no changeset should be counted twice'
    assert_equal [@b, @c, @x, @y, @d, merge].map(&:id).sort, ids.sort
  end

  def test_changesets_without_from_revision_returns_all_ancestors_of_to
    deployment = build_deployment(:from_revision => nil, :to_revision => @c.revision)

    assert_equal [@a, @b, @c].map(&:id).sort, deployment.changesets.pluck(:id).sort
  end

  def test_changesets_unavailable_when_to_revision_not_found
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => 'deadbeefdeadbeef')

    assert_empty deployment.changesets
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason
  end

  def test_changesets_unavailable_when_to_revision_blank
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => nil)

    assert_empty deployment.changesets
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason
  end

  def test_changesets_unavailable_when_dag_not_populated
    empty_repo = Repository::Git.create!(:project => Project.find(2), :url => '/tmp/empty.git')
    changeset  = Changeset.create!(
      :repository => empty_repo, :revision => 'solo', :scmid => 'solo',
      :committed_on => Time.current, :committer => 'x'
    )
    deployment = build_deployment(
      :repository => empty_repo, :from_revision => nil, :to_revision => changeset.revision
    )

    assert_empty deployment.changesets
    assert_equal :dag_unavailable, deployment.changesets_unavailable_reason
  end

  def test_changesets_is_a_chainable_relation
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    # The controller and related_issues chain preload/reorder/select on the result.
    relation = deployment.changesets
    assert_kind_of ActiveRecord::Relation, relation
    assert_nothing_raised do
      relation.preload(:user).reorder("#{Changeset.table_name}.committed_on DESC").to_a
      relation.select(:id).to_a
    end
  end

  def test_related_issues_reflects_corrected_changeset_set
    issue_in  = Issue.generate!(:project => @project)
    issue_out = Issue.generate!(:project => @project)
    @c.issues << issue_in    # reachable in A..D
    @y.issues << issue_out   # only on the unmerged side branch

    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    issue_ids  = deployment.related_issues.pluck(:id)

    assert_includes issue_ids, issue_in.id
    assert_not_includes issue_ids, issue_out.id
  end

  def test_new_deployment_requires_a_repository
    deployment = build_deployment(:repository => nil, :to_revision => 'x')

    assert_not deployment.valid?
    assert_includes deployment.errors.attribute_names, :repository
  end

  def test_existing_deployment_survives_repository_deletion
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    deployment.save!

    @repository.destroy

    deployment.reload
    assert_nil deployment.repository, 'deployment must outlive its deleted repository'
    assert deployment.valid?, 'an already-persisted deployment stays valid without a repository'
  end

  def test_changesets_empty_with_no_repository_reason_when_repository_deleted
    deployment = build_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    deployment.save!
    @repository.destroy
    deployment.reload

    assert_empty deployment.changesets
    assert_equal :no_repository, deployment.changesets_unavailable_reason
    assert_empty deployment.related_issues
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

  def build_deployment(attrs = {})
    Deployment.new({
      :project    => @project,
      :repository => @repository,
      :author     => @user,
      :result     => Deployment::RESULT_SUCCESS
    }.merge(attrs))
  end
end
