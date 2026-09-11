# frozen_string_literal: true

# The deployment settings of a project (project settings, tab "Deployment"): its own deploy environments.
class DeploymentSettingsController < ApplicationController
  menu_item :settings
  before_action :find_project_by_project_id, :authorize

  # custom = '1': the project uses its own pipeline (the table), otherwise the central one - stored in the plugin
  # settings ('projects', see DeploymentSetting)
  def update
    attributes = params[:deployment_setting] || {}
    values     = { 'custom' => attributes[:custom].to_s == '1' ? '1' : '0' }
    # the table is only submitted with an own pipeline - the stored one is kept otherwise
    values['environments'] = attributes[:environments].to_s if attributes.key?(:environments)

    DeploymentSetting.update_project(@project, values)
    flash[:notice] = l(:notice_successful_update)
    redirect_to settings_project_path(@project, :tab => 'deployment')
  end
end
