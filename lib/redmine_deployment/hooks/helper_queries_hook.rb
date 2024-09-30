module RedmineDeployment
  module Hooks
    class HelperQueriesHook < Redmine::Hook::ViewListener
      def helper_queries_column_value(context)
        return unless context[:column].item == Deployment




        # context[:content] = context[:value].identifier
        context[:content] += "MEINS"
      end
    end
  end
end