# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# the deploy status on the issue page (RedmineDeployment::Patches::IssuesHelperPatch)
class IssueDeployStatusTest < Redmine::ControllerTest
  tests IssuesController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :trackers, :projects_trackers,
           :enabled_modules, :issue_statuses, :issues, :enumerations, :journals, :journal_details, :repositories

  def setup
    Rails.cache.clear
    Setting.clear_cache
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | staging | Staging | purple\ndeployment | production | Live" }
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'deployment')
    Role.find(1).add_permission!(:view_deployments)
    @request.session[:user_id] = 2 # jsmith, manager of project 1

    @repository = Repository::Git.create!(project: @project, identifier: 'deploy', url: '/tmp/deploy.git')
    @c1 = Changeset.create!(repository: @repository, revision: 'c1', scmid: 'c1', committed_on: 3.days.ago, committer: 'tester')
    @c2 = Changeset.create!(repository: @repository, revision: 'c2', scmid: 'c2', committed_on: 2.days.ago, committer: 'tester', parents: [@c1])
    Issue.find(1).changesets << @c2
    Deployment.create!(project: @project, repository: @repository, author: User.find(1), environment: 'staging',
                       result: Deployment::RESULT_SUCCESS, to_revision: 'c2')
  end

  def teardown
    Setting.clear_cache
  end

  def test_show_should_render_the_deploy_pipeline_right_of_the_subject
    get :show, params: { id: 1 }

    assert_response :success
    assert_select 'div.issue div.subject h3', text: Issue.find(1).subject
    # in front of the subject (floats right), inside the details box
    assert_select 'div.issue div.subject span.deploy-issue-status + h3'
    assert_select 'div.issue div.subject .deploy-issue-status .deploy-pipe' do |pipe|
      # the indicator and the badge next to it
      assert_select '> .deploy-seg + .deploy-badge.deploy-badge-reached[style=?]', '--e: #7657b8', text: 'Staging'
      assert_equal %w[on on off], css_select(pipe.first, '.deploy-seg i').map { |segment| segment['class'] }
      assert_equal ['--e: #66707a', '--e: #7657b8', '--e: #2f9e44'], css_select(pipe.first, '.deploy-seg i').map { |segment| segment['style'] }
      assert_select '.deploy-badge', text: 'Staging'
      assert_match(/Staging: 1\/1/, css_select(pipe.first, '.deploy-badge').first['title'])
    end
  end

  def test_show_without_the_module_deployment
    @project.enabled_modules.where(name: 'deployment').delete_all

    get :show, params: { id: 1 }

    assert_response :success
    assert_select 'div.issue div.subject h3'
    assert_select '.deploy-issue-status', 0
  end

  def test_show_without_changesets
    get :show, params: { id: 2 }

    assert_response :success
    assert_select '.deploy-issue-status', 0
  end

  def test_show_without_the_permission
    Role.find(1).remove_permission!(:view_deployments)

    get :show, params: { id: 1 }

    assert_response :success
    assert_select '.deploy-issue-status', 0
  end

  def test_show_with_the_environments_of_the_project
    DeploymentSetting.update_project(@project, 'custom' => '1', 'environments' => "code |  | Git | red\ndeployment | staging | Stage | teal")

    get :show, params: { id: 1 }

    assert_select 'div.issue div.subject .deploy-issue-status .deploy-pipe' do |pipe|
      # the step "Code" in its color, then the environments
      assert_equal ['--e: #c93c3c', '--e: #1c8a8a'], css_select(pipe.first, '.deploy-seg i').map { |segment| segment['style'] }
      assert_select '.deploy-badge', text: 'Stage'
      assert_match(/^Git: 1 commit$/, css_select(pipe.first, '.deploy-seg').first['title'])
    end
  end

  def test_show_only_code_with_its_label
    Setting.plugin_redmine_deployment = { 'environments' => "code |  | Commits | pink\ndeployment | production | Live" }
    Deployment.where(environment: 'staging').delete_all
    Deployment.create!(project: @project, repository: @repository, author: User.find(1), environment: 'production',
                       result: Deployment::RESULT_SUCCESS, to_revision: 'c1')

    get :show, params: { id: 1 }

    assert_select '.deploy-issue-status .deploy-pipe' do |pipe|
      assert_select '.deploy-badge', text: 'Commits'
      assert_equal '--e: #c2417f', css_select(pipe.first, '.deploy-seg i').first['style']
    end
  end

  def test_show_without_deploy_environments
    Setting.plugin_redmine_deployment = { 'environments' => '' }

    get :show, params: { id: 1 }

    assert_select '.deploy-issue-status', 0
  end
end
