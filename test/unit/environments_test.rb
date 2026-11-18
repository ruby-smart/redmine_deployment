# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class EnvironmentsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :trackers, :issue_statuses, :issues, :issue_categories, :enumerations

  Environments = RubysmartDeployment::Environments

  def setup
    Setting.clear_cache
    Setting.plugin_rubysmart_deployment = {}
  end

  def teardown
    Setting.clear_cache
  end

  def test_global
    assert_equal [%w[deployment development Development], %w[deployment staging Staging], %w[deployment production Live]],
                 Environments.global.map { |environment| [environment.type, environment.value, environment.label] }

    Setting.plugin_rubysmart_deployment = { 'environments' => "branch|develop\r\n\n# comment\n  deployment |  pre prod  | Pre Prod  \n" \
                                                             "branch | develop | Duplicate\nbranch | release/2.0 | Release\n" }
    environments = Environments.global
    assert_equal [%w[branch develop Develop], ['deployment', 'pre prod', 'Pre Prod'], ['branch', 'release/2.0', 'Release']],
                 environments.map { |environment| [environment.type, environment.value, environment.label] }
    assert_equal ['branch:develop', 'deployment:pre prod', 'branch:release/2.0'], environments.map(&:key)
    assert environments.first.branch?
    assert environments.second.deployment?

    Setting.plugin_rubysmart_deployment = { 'environments' => '' }
    assert_empty Environments.global
  end

  def test_colors
    # at least 8 different colors
    assert_operator Environments::COLORS.values.uniq.size, :>=, 8
    Environments::COLORS.each_value { |color| assert_match Environments::COLOR_FORMAT, color }

    # without a color: by position, the last environment is green
    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | develop\nbranch | stage\ndeployment | qa\ndeployment | production | Live" }
    assert_equal %w[#2f6db5 #7657b8 #c98a00 #2f9e44], Environments.global.map(&:color)

    # by name or '#rrggbb', an empty label keeps the default label
    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | develop | | pink\ndeployment | production | Live | #ABCDEF\ndeployment | qa" }
    assert_equal [['Develop', '#c2417f'], ['Live', '#abcdef'], ['Qa', '#2f9e44']],
                 Environments.global.map { |environment| [environment.label, environment.color] }
  end

  def test_line
    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | develop\ndeployment | production | Live | pink" }

    lines = Environments.global.map { |environment| Environments.line(environment) }

    assert_equal ['branch | develop | Develop | #2f6db5', 'deployment | production | Live | #c2417f'], lines
    lines.each { |line| assert_match Environments::FORMAT, line }
  end

  def test_invalid_lines_are_ignored
    Setting.plugin_rubysmart_deployment = { 'environments' => "release | v1 | V1\nbranch |  | Empty\ndeployment | a | b | c\ndeployment | a | b | #12345\n" \
                                                             "Branch | main\nbranch | main | Main" }

    assert_equal ['branch:main'], Environments.global.map(&:key)
  end

  def test_legacy_lines_are_converted
    Setting.plugin_rubysmart_deployment = { 'environments' => "staging: Stage\n\nproduction\nstaging = Duplicate\nbranch | main\n" }

    assert_equal "deployment | staging | Stage\n\ndeployment | production | Production\ndeployment | staging | Duplicate\nbranch | main",
                 Environments.global_text
    assert_equal [%w[deployment:staging Stage], %w[deployment:production Production], %w[branch:main Main]],
                 Environments.global.map { |environment| [environment.key, environment.label] }
  end

  def test_pattern_is_javascript_compatible
    # the settings form checks the lines with the same pattern (new RegExp(pattern)) - no Ruby-only syntax
    assert_no_match(/\\[AzZh]|\(\?[<>imx]/, Environments::PATTERN)
    assert_match Environments::FORMAT, 'branch | feature/x-1 | Feature'
    assert_no_match Environments::FORMAT, 'branch | feature x | Feature | more'
    assert_match Environments::FORMAT, 'branch | feature/x-1 | Feature | purple'
    assert_match Environments::FORMAT, 'deployment | production | | #1a2B3c'
    assert_no_match Environments::FORMAT, 'deployment | production | Live | rot'
    assert_no_match Environments::FORMAT, 'deployment | production | Live | green | more'
  end

  def test_code
    # without a code line: the default label (nil - translated "Code") and color
    assert_equal [nil, '#66707a'], Environments.global_code.to_a

    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | develop\ncode |  | Commits | teal\ncode | | Other | red" }
    # the first code line - it is no environment
    assert_equal ['Commits', '#1c8a8a'], Environments.global_code.to_a
    assert_equal ['branch:develop'], Environments.global.map(&:key)

    # the lines of the pipeline: "Code" first
    assert_equal "code |  | Commits | #1c8a8a\nbranch | develop | Develop | #2f9e44", Environments.text(Environments.global_code, Environments.global)
    assert_equal 'code |  |  | #66707a', Environments.line(Environments::Code.new(nil, '#66707a'))
  end

  def test_code_lines_have_no_value
    assert_match Environments::FORMAT, 'code |  | Commits | #112233'
    assert_match Environments::FORMAT, 'code |'
    assert_no_match Environments::FORMAT, 'code | main | Commits'
    assert_no_match Environments::FORMAT, 'code |  | Commits | rot'
    assert_nil Environments.parse_line('code |  | Commits')
  end

  def test_the_code_of_a_project
    Setting.plugin_rubysmart_deployment = { 'environments' => "code |  | Central | blue\ndeployment | production | Live" }
    project = Project.find(1)
    assert_equal ['Central', '#2f6db5'], Environments.code_for(project).to_a

    DeploymentSetting.update_project(project, 'custom' => '1', 'environments' => "code |  | Own | pink\nbranch | main")
    assert_equal ['Own', '#c2417f'], Environments.code_for(project).to_a
    assert_equal ['Central', '#2f6db5'], Environments.code_for(Project.find(2)).to_a
  end

  def test_the_environments_of_a_project
    Setting.plugin_rubysmart_deployment = { 'environments' => "deployment | staging | Staging\ndeployment | production | Live" }
    project = Project.find(1)

    # without own environments: the central ones
    assert_equal %w[Staging Live], Environments.for(project).map(&:label)
    assert_not Environments.custom?(project)

    # own environments, but not activated: the central ones
    DeploymentSetting.update_project(project, 'custom' => '0', 'environments' => "branch | main | Main")
    assert_equal %w[Staging Live], Environments.for(project).map(&:label)

    # own environments (colors by position)
    DeploymentSetting.update_project(project, 'custom' => '1')
    assert_equal [['branch', 'main', 'Main', '#2f9e44']], Environments.for(project).map(&:to_a)
    assert Environments.custom?(project)
    assert_equal %w[Staging Live], Environments.for(Project.find(2)).map(&:label)
    assert_equal %w[Staging Live], Environments.for(nil).map(&:label)

    # own, but empty: no environments
    DeploymentSetting.update_project(project, 'environments' => '')
    assert_empty Environments.for(project)
  end

  def test_the_project_settings_are_deleted_with_the_project
    project = Project.find(2)
    DeploymentSetting.update_project(project, 'custom' => '1', 'environments' => "branch | main")

    project.destroy

    assert_empty DeploymentSetting.project_settings(2)
    assert_not DeploymentSetting.settings['projects'].to_h.key?(2)
  end

  def test_dynamic_values
    assert_match Environments::FORMAT, 'branch | feature/* | Feature'
    assert_match Environments::FORMAT, 'branch | feature/{%issue.id%}-* | Feature'
    assert_equal 'feature/*', Environments.parse_line('branch | feature/*').value

    assert_not Environments::Environment.new('branch', 'develop').dynamic?
    assert Environments::Environment.new('branch', 'feature/*').dynamic?
    assert Environments::Environment.new('deployment', 'review-{%issue.id%}').placeholders?
    assert_not Environments::Environment.new('branch', 'feature/*').placeholders?
  end

  def test_wildcards
    target = Environments.resolve('feature/*', nil)

    assert_equal 'feature/*', target.text
    assert target.match?('feature/login')
    assert target.match?('Feature/Login-2')
    assert target.match?('feature/')
    assert_not target.match?('bugfix/feature/login')
    assert_not target.match?('feature')

    assert Environments.resolve('*-{%issue.id%}-*', Issue.find(1)).match?('feature-1-login')
    assert Environments.resolve('release/*.x', nil).match?('release/2.x')
    assert_not Environments.resolve('release/*.x', nil).match?('release/2-x')
  end

  def test_literal_values_match_exactly
    target = Environments.resolve('develop', nil)

    assert target.match?('develop')
    assert_not target.match?('Develop')
    assert_not target.match?('develop2')
    assert_not Environments.resolve('release.1', nil).match?('release-1')
  end

  def test_placeholders
    issue = Issue.find(1) # Bug, project eCookbook, category 1

    assert_equal 'feature/1-*', Environments.resolve('feature/{%issue.id%}-*', issue).text
    assert_equal 'Bug/1', Environments.resolve('{%tracker.name%}/{%issue.id%}', issue).text
    assert_equal 'ecookbook-New', Environments.resolve('{% project.identifier %}-{%status.name%}', issue).text
    assert_equal 'review-jsmith', Environments.resolve('review-{%author.login%}', issue).text

    target = Environments.resolve('{%tracker.name%}/{%issue.id%}', issue)
    assert target.match?('Bug/1')
    assert target.match?('bug/1')
    assert_not target.match?('bug/12')
  end

  def test_placeholder_values_are_no_wildcards
    issue = Issue.find(1)
    issue.subject = 'a*b'

    target = Environments.resolve('x-{%issue.subject%}', issue)

    assert target.match?('x-a*b')
    assert_not target.match?('x-aXb')
  end

  def test_unresolvable_placeholders
    issue = Issue.find(1)
    issue.assigned_to = nil

    # no value: the step can't be reached
    assert_nil Environments.resolve('review-{%assigned_to.login%}', issue)
    # unknown object or attribute
    assert_nil Environments.resolve('review-{%foo.id%}', issue)
    assert_nil Environments.resolve('review-{%tracker.foo%}', issue)
    # no attributes of users other than the public ones
    assert_nil Environments.resolve('{%author.hashed_password%}', issue)
    assert_nil Environments.resolve('{%issue.id%}', nil)
    # no placeholder syntax: literal text
    assert_equal '{issue.id}', Environments.resolve('{issue.id}', issue).text
  end

  def test_tags
    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | main\ntag | /^v\\d+\\./ | Release\ntag | v2.1.0\ndeployment | production" }

    environments = Environments.global
    assert_equal ['branch:main', 'tag:/^v\\d+\\./', 'tag:v2.1.0', 'deployment:production'], environments.map(&:key)
    assert_equal [false, true, true, false], environments.map(&:tag?)
    assert_equal [true, true, true, false], environments.map(&:ref?)
    assert_equal 'V2.1.0', environments.third.label
    assert_includes Environments::TYPES, 'tag'
    assert_match Environments::FORMAT, 'tag | v* | Release | green'
  end

  def test_regexp_values
    assert_match Environments::FORMAT, 'branch | /^(develop|main)$/ | Main | purple'
    assert_match Environments::FORMAT, 'deployment | /^prod-(eu|us)/i'
    assert_no_match(/\\[AzZh]|\(\?[<>imx]/, Environments::REGEXP_PATTERN)

    environment = Environments.parse_line('branch | /^(feature|bugfix)/{%issue.id%}-/i | Feature | teal')
    assert_equal ['/^(feature|bugfix)/{%issue.id%}-/i', 'Feature', '#1c8a8a'], [environment.value, environment.label, environment.color]
    assert environment.regexp?
    assert environment.dynamic?
    assert environment.placeholders?
    # the default label is the regular expression as it is
    assert_equal '/^Main$/', Environments.parse_line('branch | /^Main$/').label
    # without slashes "|" separates the label: no regular expression
    assert_equal %w[develop main], Environments.parse_line('branch | develop|main').to_a.values_at(1, 2)

    assert_not Environments::Environment.new('branch', '/develop').regexp?
    assert_not Environments::Environment.new('branch', 'feature/x/').regexp?
    assert_not Environments::Environment.new('branch', '//').regexp?
    assert_not Environments::Environment.new('branch', '/a/x').regexp?
  end

  def test_regexps_match
    target = Environments.resolve('/^(develop|main)$/', nil)

    assert_equal '/^(develop|main)$/', target.text
    assert target.match?('develop')
    assert target.match?('main')
    assert_not target.match?('Main')
    assert_not target.match?('maintenance')

    # not anchored, case-insensitive with "i", slashes inside
    assert Environments.resolve('/release/\d+/', nil).match?('hotfix/release/2')
    assert Environments.resolve('/^PROD-/i', nil).match?('prod-eu')
    assert_not Environments.resolve('/^PROD-/', nil).match?('prod-eu')
  end

  def test_regexp_placeholders_are_literal_text
    issue = Issue.find(1)
    issue.subject = 'a.b'

    target = Environments.resolve('/^(feature|bugfix)/{%issue.id%}-{%issue.subject%}$/i', issue)

    assert_equal '/^(feature|bugfix)/1-a.b$/i', target.text
    assert target.match?('Bugfix/1-a.b')
    assert_not target.match?('feature/1-aXb')
    assert_not target.match?('feature/12-a.b')
    # no value: the step can't be reached
    assert_nil Environments.resolve('/^review-{%assigned_to.login%}$/', issue.tap { |i| i.assigned_to = nil })
  end

  def test_invalid_regexps_are_ignored
    Setting.plugin_rubysmart_deployment = { 'environments' => "branch | /^(develop/\nbranch | /[/ | Broken\nbranch | /^main$/" }

    assert_equal ['branch:/^main$/'], Environments.global.map(&:key)
    assert_nil Environments.resolve('/^(develop/', nil)
    assert Environments.valid_value?('/^{%issue.id%}+$/')
    assert_not Environments.valid_value?('/(/')
    assert Environments.valid_value?('develop')
  end

  def test_slow_regexps_do_not_match
    skip 'Regexp timeouts need Ruby >= 3.2' unless Regexp.respond_to?(:timeout)

    target = Environments.resolve('/^(a|a)*$/', nil)

    assert_equal Environments::REGEXP_TIMEOUT, target.regexp.timeout
    target.regexp.stubs(:match?).raises(Regexp::TimeoutError)
    assert_not target.match?('aaa')
  end

  def test_match_budget_limits_the_regular_expressions_of_the_settings
    target = Environments.resolve('/^v/', nil)
    assert target.custom
    assert_not Environments.resolve('v*', nil).custom

    slow = target.dup
    slow.define_singleton_method(:match?) do |_name|
      sleep(0.05)
      true
    end
    budget = Environments::MatchBudget.new(0.12)

    # used up while matching: nothing matches
    assert_equal [], budget.select(slow, %w[v1 v2 v3 v4 v5 v6])
    assert budget.exhausted?
    assert_equal [], budget.select(target, %w[v1])
    # literal values and wildcards are linear - outside the budget
    assert_equal %w[develop], budget.select(Environments.resolve('develop', nil), %w[develop main])
    assert_equal %w[v1 v2], budget.select(Environments.resolve('v*', nil), %w[v1 v2 x])
    assert_equal %w[v1 v2], Environments::MatchBudget.new.select(target, %w[v1 v2 x])
  end

  def test_match_budget_aborts_a_single_match_without_regexp_timeouts
    Environments.stubs(:regexp_timeout?).returns(false)
    target = Environments.resolve('/^v/', nil)
    target.define_singleton_method(:match?) do |_name|
      sleep(5)
      true
    end
    budget  = Environments::MatchBudget.new(0.2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal [], budget.select(target, %w[v1])
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert budget.exhausted?
  end

  def test_placeholder_associations
    environments = [Environments::Environment.new('branch', '{%tracker.name%}/{%issue.id%}'),
                    Environments::Environment.new('deployment', '{%version.name%}-{%tracker.id%}'),
                    Environments::Environment.new('branch', 'main')]

    assert_equal %i[tracker fixed_version], Environments.placeholder_associations(environments)
  end
end
