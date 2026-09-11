# frozen_string_literal: true

# The deploy status of issues (RedmineDeployment::DeployStatus) - the central methods to render it, e.g. on the issue
# page (right of the subject) and on the SCRUM taskboard of RI-Customizations. The styles are part of deployment.css.
#
# * deployment_indicator: the segments of the pipeline - "Code", then every environment
# * deployment_badge: the last reached step (the last environment with commits of the issue, otherwise "Code")
# * deployment_pipeline: indicator and badge
module DeploymentStatusHelper
  # CSS class of a pipeline segment by the state of its environment
  DEPLOYMENT_SEGMENT_STATES = { reached: 'on', partial: 'partial', none: 'off' }.freeze

  # The deploy pipeline: the indicator followed by the badge.
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  def deployment_pipeline(status)
    content_tag(:span, deployment_indicator(status) + deployment_badge(status),
                class: "deploy-pipe#{' deploy-pipe-live' if status.live?}#{' deploy-pipe-partial' if status.partial?}")
  end

  # The deploy indicator: the segments of the pipeline - "Code", then every environment by its own state in its color
  # (reached filled, partial striped, not reached grey). An environment that was skipped (e.g. not merged into
  # develop, but deployed to staging) is not shown as reached. The details are the title.
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  def deployment_indicator(status)
    segments = [content_tag(:i, '', class: 'on', style: deployment_color_style(deployment_code_color(status)))]
    status.environments.each do |environment|
      segments << content_tag(:i, '', class: DEPLOYMENT_SEGMENT_STATES[environment.state], style: deployment_color_style(environment.color))
    end

    content_tag(:span, safe_join(segments), class: 'deploy-seg', title: deployment_status_title(status))
  end

  # The deploy badge: the last reached step in its color - the last environment with commits of the issue, otherwise
  # the step "Code". States (CSS class deploy-badge-<state>): 'live' (the last environment is reached - filled),
  # 'reached' (outlined), 'partial' (newer commits pending - dashed) or 'code'. The details are the title.
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  def deployment_badge(status)
    environment = status.top_environment
    state = if environment.nil?
              'code'
            elsif environment.state == :partial
              'partial'
            else
              status.live? ? 'live' : 'reached'
            end

    content_tag(:span, environment&.label || deployment_code_label(status), class: "deploy-badge deploy-badge-#{state}",
                                                                           style: deployment_color_style(environment ? environment.color : deployment_code_color(status)),
                                                                           title: deployment_status_title(status))
  end

  # The deploy pipeline of an issue on its page (right of the subject) - only for projects with the module
  # "deployment", if the user may view its deployments, the project has environments and the issue has changesets.
  def deployment_issue_status(issue)
    return ''.html_safe unless issue.is_a?(Issue) && issue.project&.module_enabled?(:deployment)

    deploy = RedmineDeployment::DeployStatus.new([issue])
    status = deploy[issue] if deploy.enabled?
    status ? content_tag(:span, deployment_pipeline(status), class: 'deploy-issue-status') : ''.html_safe
  end

  # the color of a step as CSS variable (--e)
  def deployment_color_style(color)
    color.present? ? "--e: #{color}" : nil
  end

  # the label of the step "Code" of the project (default: "Code")
  def deployment_code_label(status)
    status.code&.label.presence || l(:label_deployment_code)
  end

  def deployment_code_color(status)
    status.code&.color.presence || RedmineDeployment::Environments::CODE_COLOR
  end

  # the last environment with commits of the issue (the step "Code" without one) - with "newer commits pending"
  def deployment_status_label(status)
    environment = status.top_environment
    return deployment_code_label(status) unless environment

    status.partial? ? l(:label_deployment_partial, environment: environment.label) : environment.label
  end

  # the indicator as text (e.g. CSV): "Code: 2 commits, Develop: 0/2, Staging: 1/2, Live: 2/2"
  def deployment_indicator_text(status)
    steps = ["#{deployment_code_label(status)}: #{l(:label_deployment_commits, count: status.changeset_count)}"] +
            status.environments.map { |environment| "#{environment.label}: #{environment.covered}/#{environment.total}" }
    steps.join(', ')
  end

  def deployment_status_title(status)
    lines = ["#{deployment_code_label(status)}: #{l(:label_deployment_commits, count: status.changeset_count)}"]
    # the status first (the badge shows the environment only)
    lines.unshift(deployment_status_label(status)) if status.top_environment
    status.environments.each do |environment|
      lines << "#{environment.label}: #{environment.covered}/#{environment.total}"
    end
    lines << l(:label_deployment_live_since, time: format_time(status.live_since)) if status.live_since
    lines.join("\n")
  end
end
