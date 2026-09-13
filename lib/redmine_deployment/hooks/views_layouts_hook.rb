
module RedmineDeployment
  module Hooks
    class ViewsLayoutsHook < Redmine::Hook::ViewListener

      # deployment_status.js opens the pipeline of an issue as a popup (the deploy status right of its subject)
      def view_layouts_base_html_head(context)
        stylesheet_link_tag("deployment.css", :plugin => 'redmine_deployment') +
          javascript_include_tag("deployment_status", :plugin => 'redmine_deployment')
      end
    end
  end
end
