# frozen_string_literal: true

# The deploy status of one issue as the popup of its indicator (deployment_status.js): wherever the indicator or the
# badge of an issue is shown - its page, the issue list, the SCRUM taskboard - a click on it asks for the pipeline
# here. It is deliberately not part of those pages: a board with 70 cards would carry it 70 times over, and it is
# only ever needed for the one card that is asked about.
class DeploymentStatusController < ApplicationController
  # the permissions, whose deploy status opens the popup (see init.rb - both of them allow the action)
  POPUP_PERMISSIONS = [:view_deployments, RedmineDeployment::DeployStatus::INDICATOR_PERMISSION].freeze

  before_action :find_issue, :authorize

  def show
    # the indicator of the issue page and the issue list opens it as well as the SCRUM taskboard
    deploy = RedmineDeployment::DeployStatus.new([@issue], permission: POPUP_PERMISSIONS)
    status = deploy[@issue] if deploy.enabled?
    return render plain: '', status: :no_content unless status

    render partial: 'pipeline', locals: { status: status, issue: @issue }
  end
end
