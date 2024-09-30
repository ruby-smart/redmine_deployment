
Redmine::Plugin.register :redmine_deployment do
  name 'Redmine deployment plugin'
  author 'Ruby Smart'
  description 'A plugin for repository deployments'
  version '1.0.0'
  url 'https://git.gonzo-hosting.de/ruby-smart/redmine_deployment'
  author_url 'https://ruby-smart.org'

  # redmine requirements
  requires_redmine version_or_higher: '4.0'

  project_module :deployment do
    permission :view_deployments, {
      :deployments => [:show, :index],
    }, :read => true, caption: :label_view_deployments

    permission :create_deployments, {
      :deployments => [:create], caption: :label_create_deployments
    }
  end

  menu :project_menu, :deployments, {controller: :deployments, action: :index}, caption: :label_deployment, param: :project_id
end

require File.dirname(__FILE__) + '/lib/redmine_deployment'