# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class IssueDeploymentsTabTest < Redmine::ControllerTest
  tests IssuesController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enumerations,
           :repositories

  def setup
    @project = Project.find(1)
    EnabledModule.create!(:project => @project, :name => 'deployment') unless
      @project.module_enabled?(:deployment)
    Role.find(1).add_permission!(:view_deployments)

    @repository = Repository::Git.create!(:project => @project, :url => '/tmp/repo.git')
    @a = create_changeset('a', 40.minutes.ago)
    @b = create_changeset('b', 20.minutes.ago, [@a])

    @issue = Issue.find(1)
    @issue.changesets << @b

    @deployment = Deployment.create!(
      :project => @project, :repository => @repository, :author => User.find(2),
      :result => Deployment::RESULT_SUCCESS,
      :from_revision => @a.revision, :to_revision => @b.revision, :environment => 'production'
    )

    @request.session[:user_id] = 2
  end

  def test_issue_tab_renders_associated_deployments
    get :issue_tab, :params => { :id => @issue.id, :name => 'deployments', :format => 'js' }, :xhr => true

    assert_response :success
    assert_select "tr#deployment-#{@deployment.id}" do
      assert_select 'td.environment', :text => 'production'
    end
  end

  def test_issue_tab_deployments_requires_permission
    Role.find(1).remove_permission!(:view_deployments)

    get :issue_tab, :params => { :id => @issue.id, :name => 'deployments', :format => 'js' }, :xhr => true

    assert_response :forbidden
  end

  def test_show_includes_deployments_tab_when_issue_has_deployments
    get :show, :params => { :id => @issue.id }

    assert_response :success
    assert_select 'div.tabs a', :text => I18n.t(:label_deployment_plural)
  end

  def test_show_omits_deployments_tab_when_issue_has_none
    other = Issue.find(2)

    get :show, :params => { :id => other.id }

    assert_response :success
    assert_select 'div.tabs a', :text => I18n.t(:label_deployment_plural), :count => 0
  end

  private

  def create_changeset(name, committed_on, parents = [])
    Changeset.create!(
      :repository => @repository, :revision => name, :scmid => name,
      :committed_on => committed_on, :committer => 'tester', :parents => parents
    )
  end
end
