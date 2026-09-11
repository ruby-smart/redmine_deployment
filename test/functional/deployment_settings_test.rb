# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# the central deploy environments (plugin settings)
class DeploymentPluginSettingsTest < Redmine::ControllerTest
  tests SettingsController

  fixtures :users, :email_addresses

  def setup
    Setting.clear_cache
    @request.session[:user_id] = 1 # admin
  end

  def teardown
    Setting.clear_cache
  end

  def test_plugin_settings_should_show_the_environments_table
    get :plugin, params: { id: 'redmine_deployment' }

    assert_response :success
    assert_select 'input[type=hidden].deployment-environments-field[name=?][data-pattern=?][data-message*=?][data-colors]',
                  'settings[environments]', RedmineDeployment::Environments::PATTERN, '%{lines}' do |field|
      assert_equal "code |  |  | #66707a\ndeployment | development | Development | #2f6db5\n" \
                   "deployment | staging | Staging | #7657b8\ndeployment | production | Live | #2f9e44", field.first['value']
      assert_nil field.first['disabled']
    end
    assert_select 'table.deployment-environments-table' do
      assert_select 'th', text: 'Type'
      # the static step "Code": first, without handle, value and delete - only label and color
      assert_select 'tbody tr.deployment-code:first-child' do
        assert_select 'td.deploy-env-static', text: 'Code'
        assert_select 'input.deploy-env-label[type=text][placeholder=Code]:not([name])'
        assert_select 'input.deploy-env-color[type=color][value=?]', '#66707a'
        assert_select '.sort-handle, .deploy-env-value, .deploy-env-type, .deploy-env-delete', 0
      end
      assert_select 'tbody tr.deployment-environment', 3
      assert_select 'tbody tr.deployment-code + tr.deployment-environment' do
        assert_select '.sort-handle'
        assert_select 'select.deploy-env-type:not([name]) option[selected][value=deployment]', text: 'Deployment'
        assert_select 'select.deploy-env-type option[value=branch]', text: 'Branch'
        assert_select 'input.deploy-env-value[type=text][value=development]:not([name])'
        assert_select 'input.deploy-env-label[type=text][value=Development]:not([name])'
        assert_select 'input.deploy-env-color[type=color][value=?]:not([name])', '#2f6db5'
        assert_select 'a.deploy-env-delete'
      end
    end
    assert_select 'template.deployment-environment-template'
    assert_select 'a.deployment-environment-add', text: 'Add environment'
    assert_select 'head script[src*=?]', 'deployment_environments'
  end

  def test_plugin_settings_should_show_former_lines_converted
    Setting.plugin_redmine_deployment = { 'environments' => "staging = Stage\nproduction = Live" }

    get :plugin, params: { id: 'redmine_deployment' }

    assert_select 'input[name=?]', 'settings[environments]' do |field|
      assert_equal "code |  |  | #66707a\ndeployment | staging | Stage | #2f6db5\ndeployment | production | Live | #2f9e44", field.first['value']
    end
  end

  def test_post_plugin_settings_should_keep_the_project_settings
    DeploymentSetting.update_project(Project.find(1), 'custom' => '1', 'environments' => 'branch | develop')

    post :plugin, params: { id: 'redmine_deployment', settings: { environments: 'deployment | production | Live' } }

    assert_response :redirect
    assert_equal 'deployment | production | Live', Setting.plugin_redmine_deployment['environments']
    assert_equal({ 1 => { 'custom' => '1', 'environments' => 'branch | develop' } }, Setting.plugin_redmine_deployment['projects'])
  end

  def test_post_plugin_settings_should_save_the_environments
    post :plugin, params: { id: 'redmine_deployment', settings: {
      environments: "code |  | Commits | #445566\r\nbranch | develop | Develop | #112233\r\ndeployment | production | Live"
    } }

    assert_response :redirect
    assert_equal [['branch:develop', 'Develop', '#112233'], ['deployment:production', 'Live', '#2f9e44']],
                 RedmineDeployment::Environments.global.map { |environment| [environment.key, environment.label, environment.color] }
    assert_equal ['Commits', '#445566'], RedmineDeployment::Environments.global_code.to_a

    get :plugin, params: { id: 'redmine_deployment' }
    assert_select 'tr.deployment-code input.deploy-env-label[value=Commits]'
    assert_select 'tr.deployment-code input.deploy-env-color[value=?]', '#445566'
  end
end

# the project's own deploy environments (project settings, tab "Deployment")
class DeploymentProjectSettingsTabTest < Redmine::ControllerTest
  tests ProjectsController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
           :projects_trackers, :issue_statuses, :enumerations

  def setup
    Setting.clear_cache
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | staging | Staging\ndeployment | production | Live" }
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'deployment')
    Role.find(1).add_permission!(:manage_deployment_settings)
    @request.session[:user_id] = 2 # jsmith, manager of project 1
  end

  def teardown
    Setting.clear_cache
  end

  def test_settings_should_show_the_central_environments_read_only
    get :settings, params: { id: 'ecookbook', tab: 'deployment' }

    assert_response :success
    assert_select 'a#tab-deployment', text: 'Deployment'
    assert_select '#tab-content-deployment form[action=?]', '/projects/ecookbook/deployment_settings' do
      assert_select 'input[name=_method][value=put]'
      assert_select 'input[type=checkbox].deployment-environments-custom[name=?]:not([checked])', 'deployment_setting[custom]'
      assert_select '.deployment-environments.deployment-environments-disabled' do
        assert_select 'input.deployment-environments-field[name=?][disabled]', 'deployment_setting[environments]'
        assert_select 'tbody tr.deployment-environment input.deploy-env-label' do |labels|
          assert_equal %w[Staging Live], labels.map { |label| label['value'] }
        end
      end
    end
  end

  def test_settings_should_show_the_own_environments
    DeploymentSetting.update_project(@project, 'custom' => '1', 'environments' => "branch | develop | Develop | pink")

    get :settings, params: { id: 'ecookbook', tab: 'deployment' }

    assert_select 'input[type=checkbox].deployment-environments-custom[checked]'
    assert_select '.deployment-environments:not(.deployment-environments-disabled)' do
      assert_select 'input.deployment-environments-field:not([disabled])' do |field|
        assert_equal "code |  |  | #66707a\nbranch | develop | Develop | #c2417f", field.first['value']
      end
      assert_select 'tbody tr.deployment-environment', 1
    end
  end

  def test_settings_without_the_permission_or_the_module
    Role.find(1).remove_permission!(:manage_deployment_settings)
    get :settings, params: { id: 'ecookbook' }
    assert_select 'a#tab-deployment', 0

    Role.find(1).add_permission!(:manage_deployment_settings)
    @project.enabled_modules.where(name: 'deployment').delete_all
    get :settings, params: { id: 'ecookbook' }
    assert_select 'a#tab-deployment', 0
  end
end

class DeploymentSettingsControllerTest < Redmine::ControllerTest
  tests DeploymentSettingsController

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules

  def setup
    Setting.clear_cache
    @project = Project.find(1)
    EnabledModule.create!(project: @project, name: 'deployment')
    Role.find(1).add_permission!(:manage_deployment_settings)
    @request.session[:user_id] = 2 # jsmith, manager of project 1
  end

  def teardown
    Setting.clear_cache
  end

  def test_update_should_save_the_own_environments
    put :update, params: { project_id: 'ecookbook', deployment_setting: {
      custom: '1', environments: "code |  | Git | red\r\nbranch | develop | Develop\r\ndeployment | production | Live"
    } }

    assert_redirected_to '/projects/ecookbook/settings/deployment'
    assert_equal [%w[branch:develop Develop], %w[deployment:production Live]],
                 RedmineDeployment::Environments.for(@project).map { |environment| [environment.key, environment.label] }
    assert_equal ['Git', '#c93c3c'], RedmineDeployment::Environments.code_for(@project).to_a
    assert RedmineDeployment::Environments.custom?(@project)
    # stored in the plugin settings like redmine_contacts: 'projects' => { <project id> => { ... } }
    assert_equal({ 'custom' => '1', 'environments' => "code |  | Git | red\r\nbranch | develop | Develop\r\ndeployment | production | Live" },
                 Setting.plugin_redmine_deployment['projects'][1])
    assert_nil Setting.plugin_redmine_deployment['environments'] # the central pipeline is untouched (default)
  end

  def test_update_without_own_environments_should_keep_the_stored_ones
    DeploymentSetting.update_project(@project, 'custom' => '1', 'environments' => 'branch | develop | Develop')

    # the disabled table is not submitted
    put :update, params: { project_id: 'ecookbook', deployment_setting: { custom: '0' } }

    assert_equal({ 'custom' => '0', 'environments' => 'branch | develop | Develop' }, DeploymentSetting.project_settings(@project))
    assert_not RedmineDeployment::Environments.custom?(@project)
  end

  def test_update_should_require_the_permission
    Role.find(1).remove_permission!(:manage_deployment_settings)

    put :update, params: { project_id: 'ecookbook', deployment_setting: { custom: '1', environments: 'branch | main' } }

    assert_response :forbidden
    assert_empty DeploymentSetting.project_settings(@project)
  end

  def test_update_should_require_the_module
    @project.enabled_modules.where(name: 'deployment').delete_all

    put :update, params: { project_id: 'ecookbook', deployment_setting: { custom: '1', environments: 'branch | main' } }

    assert_response :forbidden
  end
end
