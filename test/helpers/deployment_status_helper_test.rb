# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# the central methods to render the deploy status: indicator, badge and pipeline
class DeploymentStatusHelperTest < Redmine::HelperTest
  include DeploymentStatusHelper

  Status      = RedmineDeployment::DeployStatus::Result
  Environment = RedmineDeployment::DeployStatus::Environment
  Code        = RedmineDeployment::Environments::Code

  def test_indicator
    html = deployment_indicator(status([0, 1, 2], code: Code.new('Git', '#445566')))

    assert_select_in html, 'span.deploy-seg' do |indicator|
      assert indicator.first['title'].start_with?("Live\nGit: 2 commits"), indicator.first['title']
      assert_select 'i', 4
      assert_select 'i.on[style=?]', '--e: #445566', 1 # the step "Code"
      assert_select 'i.off[style=?]', '--e: #2f6db5'
      assert_select 'i.partial[style=?]', '--e: #7657b8'
      assert_select 'i.on[style=?]', '--e: #2f9e44'
    end
  end

  def test_badge_states
    assert_select_in deployment_badge(status([2, 2, 2])), 'span.deploy-badge.deploy-badge-live[style=?]', '--e: #2f9e44', text: 'Live'
    assert_select_in deployment_badge(status([2, 2, 0])), 'span.deploy-badge.deploy-badge-reached[style=?]', '--e: #7657b8', text: 'Staging'
    assert_select_in deployment_badge(status([2, 1, 0])), 'span.deploy-badge.deploy-badge-partial', text: 'Staging'
    # skipped environments: the last one with commits
    assert_select_in deployment_badge(status([0, 0, 2])), 'span.deploy-badge.deploy-badge-live', text: 'Live'
    # only "Code" - its label and color of the pipeline
    assert_select_in deployment_badge(status([0, 0, 0])), 'span.deploy-badge.deploy-badge-code[style=?]', '--e: #66707a', text: 'Code'
    assert_select_in deployment_badge(status([0, 0, 0], code: Code.new('Commits', '#c2417f'))),
                     'span.deploy-badge.deploy-badge-code[style=?][title^=?]', '--e: #c2417f', 'Commits: 2 commits', text: 'Commits'
  end

  # a line without room for the label (the collapsed card of the SCRUM taskboard): only the first letter
  def test_deployment_badge_short
    assert_select_in deployment_badge(status([2, 2, 2]), short: true),
                     'span.deploy-badge.deploy-badge-live.deploy-badge-short[title*=?]', 'Live: 2/2', text: 'L'
    assert_select_in deployment_badge(status([2, 2, 0]), short: true), 'span.deploy-badge-short', text: 'S'
    assert_select_in deployment_badge(status([0, 0, 0]), short: true), 'span.deploy-badge-code.deploy-badge-short', text: 'C'
    # the label of the step decides - its case is kept
    assert_select_in deployment_badge(status([0, 0, 0], code: Code.new(' commits ', '#c2417f')), short: true),
                     'span.deploy-badge-short', text: 'c'
    assert_equal '', deployment_badge_initial(nil)
  end

  def test_pipeline_is_the_indicator_and_the_badge
    html = deployment_pipeline(status([2, 2, 2]))

    assert_select_in html, 'span.deploy-pipe.deploy-pipe-live' do
      assert_select '> span.deploy-seg + span.deploy-badge.deploy-badge-live', text: 'Live'
    end
  end

  # the whole pipeline (the popup of an issue): every step with what it takes to reach it
  def test_pipeline_details
    html = deployment_pipeline_details(status([2, 1, 0], code: Code.new('Revision', '#445566')))

    assert_select_in html, 'div.deploy-steps' do
      assert_select '> span.deploy-step', 4
      assert_select '> span.deploy-step-arrow', 3
      # "Code": the commits of the issue
      assert_select '> span.deploy-step:first-child' do
        assert_select 'span.deploy-badge.deploy-badge-code[style=?]', '--e: #445566', text: 'Revision'
        assert_select 'span.deploy-step-hint', text: 'commits of the issue'
      end
      # reached, partly reached, not reached - the last one without a color of its own
      assert_select 'span.deploy-badge.deploy-badge-reached[style=?]', '--e: #2f6db5', text: 'Develop'
      assert_select 'span.deploy-badge.deploy-badge-partial[style=?]', '--e: #7657b8', text: 'Staging'
      assert_select 'span.deploy-step-off span.deploy-badge.deploy-badge-off:not([style])', text: 'Live'
      # what it takes to reach it: the environment of the deployment
      assert_select 'span.deploy-step-hint', text: 'deployed to develop'
      # how many commits of the issue a step has
      assert_select 'span.deploy-step-count', text: '1/2'
    end
    # below the steps: what the tooltip of the indicator used to carry
    assert_select_in html, 'p.deploy-steps-foot', text: /2 commits/
  end

  def test_pipeline_details_name_the_branch_of_a_branch_step_and_fill_the_last_one
    environments = [Environment.new(key: 'branch:develop', label: 'develop', color: '#2f6db5', covered: 2, total: 2),
                    Environment.new(key: 'deployment:production', label: 'LIVE', color: '#2f9e44', covered: 2, total: 2)]
    html = deployment_pipeline_details(Status.new(changeset_count: 2, code: Code.new(nil, '#66707a'),
                                                  environments: environments))

    assert_select_in html, 'div.deploy-steps' do
      assert_select 'span.deploy-step-hint', text: 'merged into develop'
      # everything is live: the last step is the filled badge
      assert_select 'span.deploy-badge.deploy-badge-live', text: 'LIVE'
    end
  end

  # a dynamic value: the value resolved for the issue
  def test_pipeline_details_name_the_resolved_value
    environments = [Environment.new(key: 'branch:feature/{%issue.id%}-*', label: 'Feature', color: '#2f6db5',
                                    target: 'feature/42-*', covered: 1, total: 1),
                    Environment.new(key: 'deployment:review-*', label: 'Review', color: '#2f9e44', target: 'review-*',
                                    covered: 0, total: 1)]
    html = deployment_pipeline_details(Status.new(changeset_count: 1, code: Code.new(nil, '#66707a'),
                                                  environments: environments))

    assert_select_in html, 'div.deploy-steps' do
      assert_select 'span.deploy-step-hint', text: 'merged into feature/42-*'
      assert_select 'span.deploy-step-hint', text: 'deployed to review-*'
    end
  end

  # the headline: the pipeline of exactly this issue - without one (the tests of the steps) it has none
  def test_pipeline_details_name_the_issue
    html = deployment_pipeline_details(status([2, 2, 2]), Issue.find(1))

    assert_select_in html, 'p.deploy-steps-head', text: 'Deployment pipeline - #1'
    assert_select_in deployment_pipeline_details(status([2, 2, 2])), 'p.deploy-steps-head', 0
  end

  # an issue without commits: the pipeline still explains itself, nothing of it is reached
  def test_pipeline_details_of_an_issue_without_commits
    html = deployment_pipeline_details(Status.new(changeset_count: 0, code: Code.new(nil, '#66707a'),
                                                  environments: [Environment.new(key: 'deployment:production', label: 'Live',
                                                                                 color: '#2f9e44', covered: 0, total: 0)]))

    assert_select_in html, 'div.deploy-steps' do
      assert_select 'span.deploy-step-off', 2
      assert_select 'span.deploy-badge.deploy-badge-off', 2
    end
  end

  private

  # covered changesets (of 2) of the environments Develop, Staging, Live
  def status(covered, code: Code.new(nil, RedmineDeployment::Environments::CODE_COLOR))
    environments = [%w[Develop #2f6db5], %w[Staging #7657b8], %w[Live #2f9e44]].each_with_index.map do |(label, color), index|
      Environment.new(key: "deployment:#{label.downcase}", label: label, color: color, covered: covered[index], total: 2)
    end
    Status.new(changeset_count: 2, code: code, environments: environments)
  end
end
