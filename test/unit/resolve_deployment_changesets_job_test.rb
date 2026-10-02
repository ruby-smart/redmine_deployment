# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# Logging a deployment (the deploy process) never waits for the commit graph: the changesets are resolved by a job
# of the background queue. ActiveJob's test adapter is used here (instead of the inline adapter of the test
# environment) to tell the enqueue apart from the work.
class ResolveDeploymentChangesetsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  fixtures :projects, :users, :repositories, :enabled_modules

  def setup
    @project    = Project.find(1)
    @repository = Repository::Git.create!(:project => @project, :url => '/tmp/job.git')
    @a = commit('a', 2.hours.ago)
    @b = commit('b', 1.hour.ago, [@a])
  end

  def test_logging_a_deployment_enqueues_the_resolution_and_does_not_compute_it
    RedmineDeployment::CommitRange.expects(:ids).never
    deployment = nil

    assert_enqueued_with(:job => ResolveDeploymentChangesetsJob) do
      deployment = Deployment.create!(:project => @project, :repository => @repository, :author => User.find(2),
                                      :result => Deployment::RESULT_SUCCESS,
                                      :from_revision => @a.revision, :to_revision => @b.revision)
    end
    assert_enqueued_with(:job => ResolveDeploymentChangesetsJob, :args => [deployment.id])

    assert_not deployment.reload.changesets_resolved?
    assert_equal :not_resolved, deployment.changesets_unavailable_reason
    assert_empty deployment.changesets
    assert_includes Deployment.changesets_pending, deployment
  end

  def test_the_job_resolves_the_changesets
    deployment = Deployment.create!(:project => @project, :repository => @repository, :author => User.find(2),
                                    :result => Deployment::RESULT_SUCCESS,
                                    :from_revision => @a.revision, :to_revision => @b.revision)

    perform_enqueued_jobs

    assert deployment.reload.changesets_resolved?
    assert_equal [@b.id], deployment.changesets.pluck(:id)
  end

  def test_the_job_ignores_a_deleted_deployment
    assert_nothing_raised { ResolveDeploymentChangesetsJob.perform_now(999_999) }
  end

  private

  def commit(name, committed_on, parents = [])
    Changeset.create!(:repository => @repository, :revision => name, :scmid => name, :committed_on => committed_on,
                      :committer => 'tester', :parents => parents)
  end
end
