
Redmine::Plugin.register :redmine_deployment do
  name 'Redmine Deployment plugin'
  author 'Ruby Smart'
  description 'A plugin for repository deployments'
  version '1.4.0'
  url 'https://github.com/ruby-smart/redmine_deployment'
  author_url 'https://ruby-smart.org'

  # redmine requirements
  requires_redmine version_or_higher: '4.0'

  # the central deploy environments (RedmineDeployment::Environments) - a project can override them
  settings default: { 'environments' => nil }, partial: 'settings/redmine_deployment'

  project_module :deployment do
    permission :view_deployments, {
      :deployments => [:show, :index, :stats, :graph],
      :deployment_status => [:show],
    }, :read => true, caption: :label_view_deployments

    # the deploy status of issues: the indicator right of the subject of the issue page and the issue query columns
    # "Deploy indicator" / "Deployment" - with the popup of the pipeline they open (not the SCRUM taskboard)
    permission :view_deployment_indicator, {
      :deployment_status => [:show],
    }, :read => true

    permission :create_deployments, {
      :deployments => [:create], caption: :label_create_deployments
    }

    # the project's own deploy environments (project settings, tab "Deployment")
    permission :manage_deployment_settings, {
      :projects => :settings, :deployment_settings => [:update]
    }, :require => :member
  end

  menu :project_menu, :deployments, {controller: :deployments, action: :index}, caption: :label_deployment, param: :project_id
  menu :application_menu, :deployments, { controller: :deployments, action: :index, project_id: nil }, caption: :label_deployment, if: Proc.new { User.current.logged? && User.current.allowed_to?(:view_deployments, nil, global: true) }
end

require File.dirname(__FILE__) + '/lib/redmine_deployment'