# frozen_string_literal: true

module RedmineDeployment
  module Patches
    module IssuesControllerPatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :issue_tab_without_deployment, :issue_tab
          alias_method :issue_tab, :issue_tab_with_deployment
        end
      end

      module InstanceMethods
        def issue_tab_with_deployment
          if params[:name] == 'deployments'
            return render_error :status => 422 unless request.xhr?
            return render_403 unless User.current.allowed_to?(:view_deployments, @project)

            @deployments = @issue.deployments.preload(:author, :repository).to_a
            render :partial => 'issues/tabs/deployments',
                   :locals => { :deployments => @deployments }
          else
            issue_tab_without_deployment
          end
        end
      end
    end
  end
end

unless IssuesController.included_modules.include?(RedmineDeployment::Patches::IssuesControllerPatch)
  IssuesController.send(:include, RedmineDeployment::Patches::IssuesControllerPatch)
end
