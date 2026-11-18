# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # A repository (e.g. the repository column of the deployment list) is rendered as a link to the repository.
    #
    # Prepended, not alias_method-chained: the RedmineUP plugins prepend ApplicationHelper#format_object as well since
    # Redmine 7, and an alias chain over a prepended method recurses endlessly ("no superclass method `format_object'").
    module ApplicationHelperPatch
      def format_object(object, html = true, &block)
        case object
        when Repository
          html ? link_to(object.identifier, controller: :repositories, action: :show, repository_id: object.identifier, id: object.project.identifier) : object.identifier
        else
          super
        end
      end
    end
  end
end

unless ApplicationHelper.include?(RubysmartDeployment::Patches::ApplicationHelperPatch)
  ApplicationHelper.prepend(RubysmartDeployment::Patches::ApplicationHelperPatch)
end
