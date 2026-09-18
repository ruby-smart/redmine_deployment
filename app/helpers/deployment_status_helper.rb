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
  # @param [Boolean] title - false: without the details as tooltip (the issue page shows them in its popup instead)
  def deployment_pipeline(status, title: true)
    content_tag(:span, deployment_indicator(status, title: title) + deployment_badge(status, title: title),
                class: "deploy-pipe#{' deploy-pipe-live' if status.live?}#{' deploy-pipe-partial' if status.partial?}")
  end

  # The deploy indicator: the segments of the pipeline - "Code", then every environment by its own state in its color
  # (reached filled, partial striped, not reached grey). An environment that was skipped (e.g. not merged into
  # develop, but deployed to staging) is not shown as reached. The details are the title.
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  def deployment_indicator(status, title: true)
    segments = [content_tag(:i, '', class: 'on', style: deployment_color_style(deployment_code_color(status)))]
    status.environments.each do |environment|
      segments << content_tag(:i, '', class: DEPLOYMENT_SEGMENT_STATES[environment.state], style: deployment_color_style(environment.color))
    end

    content_tag(:span, safe_join(segments), class: 'deploy-seg', title: (deployment_status_title(status) if title))
  end

  # The deploy badge: the last reached step in its color - the last environment with commits of the issue, otherwise
  # the step "Code". States (CSS class deploy-badge-<state>): 'live' (the last environment is reached - filled),
  # 'reached' (outlined), 'partial' (newer commits pending - dashed) or 'code'. The details are the title.
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  # @param [Boolean] short - only the first letter of the step (a line without room for its label, e.g. the collapsed
  #   card of the SCRUM taskboard); the whole label stays in the title
  def deployment_badge(status, short: false, title: true)
    environment = status.top_environment
    state = if environment.nil?
              'code'
            elsif environment.state == :partial
              'partial'
            else
              status.live? ? 'live' : 'reached'
            end
    label = environment&.label || deployment_code_label(status)

    content_tag(:span, short ? deployment_badge_initial(label) : label,
                class: "deploy-badge deploy-badge-#{state}#{' deploy-badge-short' if short}",
                style: deployment_color_style(environment ? environment.color : deployment_code_color(status)),
                title: (deployment_status_title(status) if title))
  end

  # @return [String] the first letter of the label of a step (its own case is kept - it is configured)
  def deployment_badge_initial(label)
    label.to_s.strip.first.to_s
  end

  # The deploy pipeline of an issue on its page (right of the subject) - only for projects with the module
  # "deployment", if the user has the permission +view_deployment_indicator+ (not +view_deployments+), the project has
  # environments and the issue has changesets.
  #
  # A click on it opens the whole pipeline as a popup (deployment_status.js), which says everything the tooltip of the
  # indicator used to - so it carries none here.
  def deployment_issue_status(issue)
    return ''.html_safe unless issue.is_a?(Issue) && issue.project&.module_enabled?(:deployment)
    # the project decides whether its issue pages carry it (project settings, tab "Deployment")
    return ''.html_safe unless DeploymentSetting.issue_indicator?(issue.project)

    deploy = RedmineDeployment::DeployStatus.new([issue], permission: RedmineDeployment::DeployStatus::INDICATOR_PERMISSION)
    status = deploy[issue] if deploy.enabled?
    return ''.html_safe unless status

    content_tag(:span, deployment_status_toggle(issue) { deployment_pipeline(status, title: false) },
                class: 'deploy-issue-status')
  end

  # The deploy status of an issue as the button that opens its pipeline (deployment_status.js loads it from
  # +data-url+ when it is clicked): every place that shows the indicator or the badge of an issue wraps it in here.
  # The tooltip of the indicator is gone with it - the popup says all of it, and more.
  #
  # @param [Issue, Integer] issue - the issue or its id
  # @yieldreturn [String] the indicator, the badge or both
  def deployment_status_toggle(issue, &block)
    id = issue.is_a?(Issue) ? issue.id : issue.to_i
    return capture(&block) unless id.positive?

    content_tag(:button, capture(&block), type: 'button', class: 'deploy-status-toggle',
                                          data: { url: issue_deployment_pipeline_path(id) },
                                          aria: { expanded: 'false', label: l(:label_deployment_pipeline_show) })
  end

  # The detailed pipeline (the popup of the issue page): every step of the pipeline of the project with what it takes
  # to reach it - the steps the issue has reached in their color, the ones it has not in grey.
  #
  # the steps of the pipeline, separated by arrows: "Code" and every environment as its badge, below it the condition
  #
  # @param [RedmineDeployment::DeployStatus::Result] status
  # @param [Issue, nil] issue - names the issue in the headline ("Deployment-Pipeline - #42")
  def deployment_pipeline_details(status, issue = nil)
    deployment_pipeline_head(issue) + deployment_pipeline_body(status)
  end

  # the headline of the popup: the pipeline and the issue it is shown for
  def deployment_pipeline_head(issue)
    return ''.html_safe unless issue

    content_tag(:p, "#{l(:label_deployment_environments)} - ##{issue.is_a?(Issue) ? issue.id : issue}",
                class: 'deploy-steps-head')
  end

  def deployment_pipeline_body(status)
    reached = status.changeset_count.positive?
    # the commits of the issue are the count of the whole pipeline (see deployment_pipeline_foot), not of its first step
    steps   = [deployment_pipeline_step(deployment_code_label(status), deployment_code_color(status),
                                        l(:text_deployment_step_code), reached ? 'code' : 'off', nil)]

    status.environments.each_with_index do |environment, index|
      count = "#{environment.covered}/#{environment.total}" if environment.total.to_i.positive?
      steps << deployment_pipeline_step(environment.label, environment.color, deployment_step_hint(environment),
                                        deployment_step_state(status, environment, index), count)
    end

    pipeline = content_tag(:div, safe_join(steps, content_tag(:span, '→', class: 'deploy-step-arrow')), class: 'deploy-steps')

    pipeline + deployment_pipeline_foot(status)
  end

  # below the steps: the commits of the issue and, once everything is live, since when
  def deployment_pipeline_foot(status)
    lines = [l(:label_deployment_commits, count: status.changeset_count)]
    lines << l(:label_deployment_live_since, time: format_time(status.live_since)) if status.live_since

    content_tag(:p, lines.join(' · '), class: 'deploy-steps-foot')
  end

  # the state of a step of the detailed pipeline (its CSS class): 'live' (the last one, all commits), 'reached',
  # 'partial' (newer commits pending) or 'off' (not reached)
  def deployment_step_state(status, environment, index)
    case environment.state
    when :none then 'off'
    when :partial then 'partial'
    else index + 1 == status.environments.size && status.live? ? 'live' : 'reached'
    end
  end

  # What it takes to reach an environment - derived from its type and its value ("branch:develop" is merged into the
  # branch "develop", "deployment:staging" is deployed to the environment "staging") - a dynamic value resolved for the
  # issue (e.g. "feature/42-*" for "feature/{%issue.id%}-*").
  def deployment_step_hint(environment)
    type, value = environment.key.to_s.split(':', 2)
    value = environment.target if environment.respond_to?(:target) && environment.target.present?

    case type
    when RedmineDeployment::Environments::CODE_TYPE then l(:text_deployment_step_code)
    when 'branch' then l(:text_deployment_step_branch, branch: value)
    else l(:text_deployment_step_deployment, environment: value)
    end
  end

  # one step of the detailed pipeline: its badge, what it takes to reach it and how many commits of the issue it has
  def deployment_pipeline_step(label, color, hint, state, count)
    badge = content_tag(:span, label, class: "deploy-badge deploy-badge-#{state}",
                                      style: (deployment_color_style(color) unless state == 'off'))
    lines = [badge, content_tag(:span, hint, class: 'deploy-step-hint')]
    lines << content_tag(:span, count, class: 'deploy-step-count') if count.present?

    content_tag(:span, safe_join(lines), class: "deploy-step deploy-step-#{state}")
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
