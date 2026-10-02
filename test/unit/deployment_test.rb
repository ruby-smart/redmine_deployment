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

  # the changesets are resolved right after the deployment is logged (ResolveDeploymentChangesetsJob - inline in
  # the test environment) and stored, so every lookup below is an indexed query
  def test_changesets_returns_only_commits_in_the_from_to_range
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert deployment.changesets_resolved?
    assert_equal [@b, @c, @d].map(&:id).sort, deployment.changesets.pluck(:id).sort
    assert_equal [@b, @c, @d].map(&:id).sort, deployment.deployment_changesets.pluck(:changeset_id).sort
    assert_nil deployment.changesets_unavailable_reason
  end

  def test_changesets_excludes_unmerged_side_branch_in_time_window
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    ids = deployment.changesets.pluck(:id)
    assert_not_includes ids, @x.id, 'unmerged side-branch commit must be excluded'
    assert_not_includes ids, @y.id, 'unmerged side-branch commit must be excluded'

    # Guard: the side-branch commits ARE inside the naive commit-time window, proving the
    # regression this fix addresses would otherwise include them.
    assert @x.committed_on > @a.committed_on
    assert @x.committed_on < @d.committed_on
  end

  def test_changesets_excludes_the_from_revision_itself
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    assert_not_includes deployment.changesets.pluck(:id), @a.id
  end

  def test_changesets_counts_merge_diamond_once
    # Merge M brings the side branch back in: D's history reaches B via two paths (C and Y).
    merge = create_changeset('m', 5.minutes.ago, [@d, @y])
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => merge.revision)

    ids = deployment.changesets.pluck(:id)
    assert_equal ids, ids.uniq, 'no changeset should be counted twice'
    assert_equal [@b, @c, @x, @y, @d, merge].map(&:id).sort, ids.sort
  end

  # The range is read from the stored rows - nothing is computed in a request, however many changesets the
  # repository has.
  def test_changesets_does_not_read_the_commit_graph
    deployment = Deployment.find(create_deployment(:from_revision => @a.revision, :to_revision => @d.revision).id)
    RedmineDeployment::CommitRange.expects(:ids).never

    queries = count_queries do
      assert_equal [@b, @c, @d].map(&:id).sort, deployment.changesets.pluck(:id).sort
      assert_empty deployment.related_issues.to_a
    end

    # the repository, the changesets, the issues - no walk, no query per commit
    assert_operator queries, :<=, 3, "#{queries} queries for a stored range"
  end

  # A deployment without a from_revision has no defined range - it must NOT be read as
  # "everything since the root commit", which would make it claim the whole repository
  # history (and every issue referenced by it) and stall the detail page.
  def test_changesets_without_from_revision_is_empty
    deployment = create_deployment(:from_revision => nil, :to_revision => @c.revision)

    assert deployment.changesets_resolved?, 'no range at all - nothing to wait for'
    assert_empty deployment.changesets
    assert_empty deployment.related_issues
    assert_equal :incomplete_range, deployment.changesets_unavailable_reason
  end

  def test_changesets_without_any_revision_is_empty
    deployment = create_deployment(:from_revision => nil, :to_revision => nil)

    assert_empty deployment.changesets
    assert_empty deployment.related_issues
    assert_equal :incomplete_range, deployment.changesets_unavailable_reason
  end

  # Git's hooks report "no revision" as an all-zero SHA, and deploy scripts abbreviate it to any
  # number of zeros. Such a boundary means "unknown", so the deployment has no range.
  def test_null_revision_predicate
    ['', nil, '0', '000000', '0' * 40, '  000000  '].each do |value|
      assert Deployment.null_revision?(value), "#{value.inspect} must count as no revision"
    end
    ['0abc1234', '000000abc', @a.revision].each do |value|
      assert_not Deployment.null_revision?(value), "#{value.inspect} is a real revision"
    end
  end

  def test_changesets_with_null_from_revision_is_empty
    ['000000', '0' * 40].each do |null_revision|
      deployment = create_deployment(:from_revision => null_revision, :to_revision => @d.revision)

      assert_empty deployment.changesets, "#{null_revision} must not open the range"
      assert_empty deployment.related_issues
      assert_equal :incomplete_range, deployment.changesets_unavailable_reason
    end
  end

  # Repository::Git#find_changeset_by_name falls back to an "scmid LIKE '<name>%'" prefix match,
  # so a short "000000" would otherwise resolve to any commit whose id happens to start with
  # zeros - turning an unknown boundary into an arbitrary range.
  def test_null_revision_is_not_prefix_matched_against_a_zero_leading_commit
    zero_leading = create_changeset('000000deadbeef', 2.hours.ago)
    deployment   = create_deployment(:from_revision => '000000', :to_revision => @d.revision)

    assert_equal zero_leading, @repository.find_changeset_by_name('000000'),
                 'guard: the repository itself would resolve the placeholder to this commit'
    assert_empty deployment.changesets
    assert_equal :incomplete_range, deployment.changesets_unavailable_reason
  end

  def test_revisions_label_treats_a_null_revision_as_missing
    assert_equal "? ... #{@d.revision[0..7]}",
                 build_deployment(:from_revision => '000000', :to_revision => @d.revision).revisions
    assert_equal '-', build_deployment(:from_revision => '000000', :to_revision => '0' * 40).revisions
  end

  def test_changesets_unavailable_when_to_revision_not_found
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => 'deadbeefdeadbeef')

    assert_not deployment.changesets_resolved?
    assert_empty deployment.changesets
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason
  end

  # An unresolvable from_revision must not silently degrade to "no lower bound" either.
  def test_changesets_unavailable_when_from_revision_not_found
    deployment = create_deployment(:from_revision => 'deadbeefdeadbeef', :to_revision => @d.revision)

    assert_empty deployment.changesets
    assert_empty deployment.related_issues
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason
  end

  def test_changesets_unavailable_when_to_revision_blank
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => nil)

    assert_empty deployment.changesets
    assert_equal :incomplete_range, deployment.changesets_unavailable_reason
  end

  def test_changesets_unavailable_when_dag_not_populated
    empty_repo = Repository::Git.create!(:project => Project.find(2), :url => '/tmp/empty.git')
    first      = Changeset.create!(
      :repository => empty_repo, :revision => 'solo1', :scmid => 'solo1',
      :committed_on => 1.hour.ago, :committer => 'x'
    )
    second     = Changeset.create!(
      :repository => empty_repo, :revision => 'solo2', :scmid => 'solo2',
      :committed_on => Time.current, :committer => 'x'
    )
    deployment = create_deployment(
      :repository    => empty_repo,
      :from_revision => first.revision,
      :to_revision   => second.revision
    )

    assert_not deployment.changesets_resolved?
    assert_empty deployment.changesets
    assert_equal :dag_unavailable, deployment.changesets_unavailable_reason
  end

  # The usual order of events: the deploy hook logs the deployment right after the push, Redmine fetches the
  # commits later. The deployment stays pending until then and is resolved by the next attempt.
  def test_pending_deployment_is_resolved_once_its_revision_is_fetched
    deployment = create_deployment(:from_revision => @c.revision, :to_revision => 'e')
    assert_equal :revision_not_found, deployment.changesets_unavailable_reason
    assert_includes Deployment.changesets_pending, deployment

    e = create_changeset('e', 1.minute.ago, [@d])

    assert deployment.resolve_changesets!
    assert deployment.changesets_resolved?
    assert_nil deployment.changesets_error
    assert_nil deployment.changesets_unavailable_reason
    assert_equal [@d.id, e.id].sort, deployment.changesets.pluck(:id).sort
    assert_not_includes Deployment.changesets_pending, deployment
  end

  # the fetch of the repository (Repository::Git#save_revisions) resolves its pending deployments
  def test_pending_deployments_are_resolved_when_the_repository_fetches_changesets
    deployment = create_deployment(:from_revision => @d.revision, :to_revision => 'e')
    assert_not deployment.changesets_resolved?

    fetched = Redmine::Scm::Adapters::Revision.new(
      :identifier => 'e', :scmid => 'e', :author => 'tester', :time => 1.minute.ago, :message => 'fetched',
      :paths => [], :parents => [@d.revision]
    )
    Repository::Git.any_instance.stubs(:scm).returns(stub(:revisions => [fetched]))

    @repository.send(:save_revisions, [@d.revision], ['e'])

    e = @repository.changesets.find_by!(:revision => 'e')
    assert_equal [@d.id], e.parents.map(&:id), 'guard: the fetched commit is stored with its parent'
    deployment.reload
    assert deployment.changesets_resolved?
    assert_equal [e.id], deployment.changesets.pluck(:id)
  end

  def test_resolve_changesets_again_replaces_the_stored_rows
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    DeploymentChangeset.where(:deployment_id => deployment.id).delete_all
    DeploymentChangeset.create!(:deployment_id => deployment.id, :changeset_id => @x.id) # stale

    assert deployment.resolve_changesets!

    assert_equal [@b, @c, @d].map(&:id).sort, deployment.changesets.pluck(:id).sort
    assert_equal 3, DeploymentChangeset.where(:deployment_id => deployment.id).count, 'no duplicates, no stale rows'
  end

  def test_resolve_changesets_of_a_scope_reports_a_summary
    create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    create_deployment(:from_revision => @a.revision, :to_revision => 'unknown')
    create_deployment(:from_revision => nil, :to_revision => @d.revision)
    assert_equal 1, Deployment.changesets_pending.count

    summary = Deployment.resolve_changesets!(Deployment.all)

    assert_equal 2, summary[:resolved]
    assert_equal({ 'revision_not_found' => 1 }, summary[:unresolved])
    # the pending ones only, by default
    assert_equal({ :resolved => 0, :unresolved => { 'revision_not_found' => 1 } }, Deployment.resolve_changesets!)
  end

  def test_changesets_is_a_chainable_relation
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

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

    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    issue_ids  = deployment.related_issues.pluck(:id)

    assert_includes issue_ids, issue_in.id
    assert_not_includes issue_ids, issue_out.id
  end

  def test_new_deployment_requires_a_repository
    deployment = build_deployment(:repository => nil, :to_revision => 'x')

    assert_not deployment.valid?
    assert_includes deployment.errors.attribute_names, :repository
    assert_not deployment.resolve_changesets!, 'nothing to store for an unsaved deployment'
  end

  def test_existing_deployment_survives_repository_deletion
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)

    @repository.destroy

    deployment.reload
    assert_nil deployment.repository, 'deployment must outlive its deleted repository'
    assert deployment.valid?, 'an already-persisted deployment stays valid without a repository'
  end

  def test_changesets_empty_with_no_repository_reason_when_repository_deleted
    deployment = create_deployment(:from_revision => @a.revision, :to_revision => @d.revision)
    @repository.destroy
    deployment.reload

    assert_empty deployment.changesets
    assert_equal :no_repository, deployment.changesets_unavailable_reason
    assert_empty deployment.related_issues
    assert_equal 0, DeploymentChangeset.where(:deployment_id => deployment.id).count, 'gone with the changesets'
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

  # saved and reloaded: the changesets are resolved by ResolveDeploymentChangesetsJob (inline in the test
  # environment) on another instance of the deployment
  def create_deployment(attrs = {})
    deployment = build_deployment(attrs)
    deployment.save!
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
