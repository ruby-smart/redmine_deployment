# frozen_string_literal: true

# The deploy status of one issue as the popup of its indicator (deployment_status.js): wherever the indicator or the
# badge of an issue is shown - its page, the issue list, the SCRUM taskboard - a click on it asks for the pipeline
# here. It is deliberately not part of those pages: a board with 70 cards would carry it 70 times over, and it is
# only ever needed for the one card that is asked about.
class DeploymentStatusController < ApplicationController
  before_action :find_issue, :authorize

  def show
    deploy = RedmineDeployment::DeployStatus.new([@issue])
    status = deploy[@issue] if deploy.enabled?
    return render plain: '', status: :no_content unless status

    render partial: 'pipeline', locals: { status: status, issue: @issue }
  end
end
