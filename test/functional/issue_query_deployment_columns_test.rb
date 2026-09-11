# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# the columns "deploy indicator" and "deploy badge" of issue queries (RedmineDeployment::Patches::IssueQueryPatch)
class IssueQueryDeploymentColumnsTest < Redmine::ControllerTest
  tests IssuesController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :trackers, :projects_trackers,
           :enabled_modules, :issue_statuses, :issues, :enumerations, :repositories, :queries

  COLUMNS = %w[subject deployment_indicator deployment_badge].freeze

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
    Issue.find(3).changesets << @c1
    Deployment.create!(project: @project, repository: @repository, author: User.find(1), environment: 'staging',
                       result: Deployment::RESULT_SUCCESS, to_revision: 'c2')
  end

  def teardown
    Setting.clear_cache
  end

  def test_index_should_render_the_deploy_columns
    get :index, params: { project_id: 'ecookbook', set_filter: 1, c: COLUMNS }

    assert_response :success
    assert_select 'table.list.issues th', text: 'Deploy indicator'
    assert_select 'table.list.issues th', text: 'Deploy badge'
    assert_select 'tr#issue-1' do
      assert_select 'td.deployment_indicator span.deploy-seg' do
        assert_select 'i', 3
        assert_select 'i.on', 2 # Code, Staging
      end
      assert_select 'td.deployment_badge span.deploy-badge.deploy-badge-reached[style=?]', '--e: #7657b8', text: 'Staging'
    end
    # no changesets: empty cells
    assert_select 'tr#issue-2 td.deployment_indicator', text: ''
    assert_select 'tr#issue-2 td.deployment_badge *', 0
  end

  def test_index_should_load_the_deploy_statuses_at_once
    deploy = RedmineDeployment::DeployStatus.new(Issue.where(project_id: [1, 3, 5]).to_a, user: User.find(2))
    RedmineDeployment::DeployStatus.expects(:new).once.returns(deploy)

    get :index, params: { project_id: 'ecookbook', set_filter: 1, c: COLUMNS }

    assert_response :success
    assert_select 'td.deployment_badge .deploy-badge', 2 # issues 1 and 3
  end

  def test_index_without_the_deploy_columns_should_not_load_the_deploy_statuses
    RedmineDeployment::DeployStatus.expects(:new).never

    get :index, params: { project_id: 'ecookbook', set_filter: 1, c: %w[subject] }

    assert_response :success
  end

  def test_the_columns_are_available_with_the_module_and_the_permission
    User.current = User.find(2)
    names = ->(query) { query.available_columns.map(&:name) }

    assert_includes names.call(IssueQuery.new(project: @project)), :deployment_indicator
    assert_includes names.call(IssueQuery.new(project: @project)), :deployment_badge
    assert_includes names.call(IssueQuery.new), :deployment_badge

    @project.enabled_modules.where(name: 'deployment').delete_all
    assert_not_includes names.call(IssueQuery.new(project: @project.reload)), :deployment_badge

    Role.find(1).remove_permission!(:view_deployments)
    User.current = User.find(2) # the roles of a user are memoized
    assert_not_includes names.call(IssueQuery.new), :deployment_indicator
  ensure
    User.current = nil
  end

  def test_index_csv_should_export_the_deploy_status_as_text
    get :index, params: { project_id: 'ecookbook', set_filter: 1, c: COLUMNS, format: 'csv' }

    assert_response :success
    lines = response.body.lines.map(&:chomp)
    assert_include 'Deploy indicator', lines.first
    assert_include 'Deploy badge', lines.first
    assert(lines.any? { |line| line.include?('Code: 1 commit, Staging: 1/1, Live: 0/1') && line.include?('Staging') }, lines.join("\n"))
  end
end
