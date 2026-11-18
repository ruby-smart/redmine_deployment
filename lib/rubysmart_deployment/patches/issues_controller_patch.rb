# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # Serves the content of the tab "Deployment" on the issue page.
    #
    # Prepended, not alias_method-chained, so it composes with the other plugins that prepend
    # IssuesController#issue_tab.
    module IssuesControllerPatch
      def issue_tab
        if params[:name] == 'deployments'
          return render_error :status => 422 unless request.xhr?
          return render_403 unless User.current.allowed_to?(:view_deployments, @project)

          @deployments = @issue.deployments.preload(:author, :repository).to_a
          render :partial => 'issues/tabs/deployments',
                 :locals => { :deployments => @deployments }
        else
          super
        end
      end
    end
  end
end

unless IssuesController.include?(RubysmartDeployment::Patches::IssuesControllerPatch)
  IssuesController.prepend(RubysmartDeployment::Patches::IssuesControllerPatch)
end
