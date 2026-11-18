
module RubysmartDeployment
  module Hooks
    class ViewsLayoutsHook < Redmine::Hook::ViewListener

      # deployment_status.js opens the pipeline of an issue as a popup (the deploy status right of its subject)
      def view_layouts_base_html_head(context)
        stylesheet_link_tag("deployment.css", :plugin => 'rubysmart_deployment') +
          javascript_include_tag("deployment_status", :plugin => 'rubysmart_deployment')
      end
    end
  end
end
