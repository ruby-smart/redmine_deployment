
module RedmineDeployment
  module Hooks
    class ViewsLayoutsHook < Redmine::Hook::ViewListener

      def view_layouts_base_html_head(context)
        stylesheet_link_tag "deployment.css", :plugin => 'redmine_deployment'
      end
    end
  end
end
