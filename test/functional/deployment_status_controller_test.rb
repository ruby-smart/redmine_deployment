# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# The pipeline of one issue: it is asked for when its deploy status is clicked (deployment_status.js), so no page
# carries it for issues nobody looks at.
class DeploymentStatusControllerTest < Redmine::ControllerTest
  tests DeploymentStatusController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enumerations, :repositories

  def setup
    # the commit range of a deployment is cached
    Rails.cache.clear
    Setting.clear_cache
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | staging | Staging\ndeployment | production | Live" }

    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'deployment') unless @project.module_enabled?(:deployment)
    Role.find(1).add_permission!(:view_deployments)

    @repository = Repository::Git.create!(project: @project, identifier: 'status', url: '/tmp/status.git')
    @c1 = Changeset.create!(repository: @repository, revision: 'c1', scmid: 'c1', committed_on: 3.days.ago, committer: 'tester')
    @c2 = Changeset.create!(repository: @repository, revision: 'c2', scmid: 'c2', committed_on: 2.days.ago,
                            committer: 'tester', parents: [@c1])
    @issue = Issue.find(1)
    @issue.changesets << @c2
    Deployment.create!(project: @project, repository: @repository, author: User.find(1), environment: 'staging',
                       result: Deployment::RESULT_SUCCESS, to_revision: 'c2')

    @request.session[:user_id] = 2
  end

  def teardown
    Setting.clear_cache
  end

  def test_show_renders_the_whole_pipeline_of_the_issue
    get :show, params: { id: @issue.id }, xhr: true

    assert_response :success
    # the headline names the pipeline and the issue it belongs to
    assert_select 'p.deploy-steps-head', text: "Deployment pipeline - ##{@issue.id}"
    assert_select 'div.deploy-steps' do
      # Code, Staging (reached), Live (not reached)
      assert_select 'span.deploy-step', 3
      assert_select 'span.deploy-step-arrow', 2
      assert_select 'span.deploy-badge.deploy-badge-reached', text: 'Staging'
      assert_select 'span.deploy-step-hint', text: 'deployed to staging'
      assert_select 'span.deploy-step-off span.deploy-badge.deploy-badge-off', text: 'Live'
      assert_select 'span.deploy-step-count', text: '1/1'
    end
    assert_select 'p.deploy-steps-foot', text: /1 commit/
  end

  def test_show_requires_the_permission
    Role.find(1).remove_permission!(:view_deployments)

    get :show, params: { id: @issue.id }, xhr: true

    assert_response :forbidden
  end

  def test_show_of_an_issue_without_a_deploy_status
    get :show, params: { id: 2 }, xhr: true # no changesets

    assert_response :no_content
    assert_equal '', response.body
  end

  def test_show_without_the_module
    @project.enabled_modules.where(name: 'deployment').delete_all

    get :show, params: { id: @issue.id }, xhr: true

    assert_response :forbidden
  end

  def test_show_of_an_unknown_issue
    get :show, params: { id: 999_999 }, xhr: true

    assert_response :not_found
  end
end
