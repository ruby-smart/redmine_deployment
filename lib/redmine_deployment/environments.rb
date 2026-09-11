# frozen_string_literal: true

module RedmineDeployment
  # The deployment pipeline (e.g. the deploy status of an issue): "Code" (the changesets of the issue - a static step,
  # only its label and color can be changed), followed by the deploy environments.
  #
  # It is managed centrally in the plugin settings (Administration » Plugins) and can be overridden by a project
  # (project settings, tab "Deployment" - see DeploymentSetting: plugin settings 'projects'). Both are stored as text,
  # one step per line:
  # "code | | <label> | <color>" and "<type> | <value> | <label> | <color>" - the settings forms edit them as a table.
  #
  # An environment is reached by
  # * branch: merged into a branch of the repository (e.g. "branch | develop | Develop")
  # * deployment: a successful deployment of the environment (e.g. "deployment | production | Live")
  module Environments
    DEFAULT_TEXT = "deployment | development | Development\ndeployment | staging | Staging\ndeployment | production | Live"

    COLOR_FORMAT = /\A#\h{6}\z/.freeze

    # The colors of the environments: by name or '#rrggbb' in the line, otherwise by position (DEFAULT_COLORS) - the
    # last environment is green.
    COLORS = {
      'blue' => '#2f6db5',
      'purple' => '#7657b8',
      'amber' => '#c98a00',
      'teal' => '#1c8a8a',
      'pink' => '#c2417f',
      'indigo' => '#4c5fd5',
      'orange' => '#d9622b',
      'brown' => '#8a5a2b',
      'lime' => '#6f9a12',
      'red' => '#c93c3c',
      'grey' => '#6b7280',
      'green' => '#2f9e44'
    }.freeze
    DEFAULT_COLORS = %w[blue purple amber teal pink indigo orange brown lime red].freeze
    LAST_COLOR     = 'green'
    # the default color of the step "Code"
    CODE_COLOR = '#66707a'

    # the types of the environments - "code" is the static first step of the pipeline
    TYPES     = %w[branch deployment].freeze
    CODE_TYPE = 'code'
    # One line: "<type> | <branch or environment> | <label> | <color>" or "code | | <label> | <color>" (without a
    # value) - the label and the color (COLORS name or '#rrggbb') are optional. The settings forms check every row
    # with this pattern (JS), so it is JS-compatible.
    PATTERN = '^\s*(?:(branch|deployment)\s*\|\s*([^|\s](?:[^|]*[^|\s])?)|(code)\s*\|)\s*' \
              "(?:\\|\\s*([^|]*?)\\s*(?:\\|\\s*(#[0-9a-fA-F]{6}|#{COLORS.keys.join('|')})\\s*)?)?$"
    FORMAT  = Regexp.new(PATTERN)
    # empty lines and comments ("# ...") are ignored
    IGNORED = /\A\s*(#.*)?\z/.freeze
    # the former format: "<deployment environment> = <label>"
    LEGACY_FORMAT = /\A\s*([^|=:#\s][^|=:]*?)\s*(?:[=:]\s*([^|]*?))?\s*\z/.freeze

    # the step "Code" - label nil: the default label (translated "Code")
    Code = Struct.new(:label, :color) do
      def type
        CODE_TYPE
      end
    end

    Environment = Struct.new(:type, :value, :label, :color) do
      def key
        "#{type}:#{value}"
      end

      def branch?
        type == 'branch'
      end

      def deployment?
        type == 'deployment'
      end
    end

    class << self
      # @param [Project, nil] project - nil: the central environments
      # @return [Array<Environment>] the environments of the project: its own ones (if it overrides them) or the
      #   central ones
      def for(project)
        parse(text_for(project))
      end

      # @return [Array<Environment>] the central environments (plugin settings)
      def global
        parse(global_text)
      end

      # @return [Code] the step "Code" of the project (its own pipeline or the central one)
      def code_for(project)
        parse_code(text_for(project))
      end

      # @return [Code] the central step "Code"
      def global_code
        parse_code(global_text)
      end

      # the environments of a project as text: its own ones (if it overrides them) or the central ones
      def text_for(project)
        project && DeploymentSetting.custom?(project) ? normalize(DeploymentSetting['environments', project]) : global_text
      end

      # the central environments as text (plugin settings) - DEFAULT_TEXT without a setting
      def global_text
        value = DeploymentSetting['environments']
        value.nil? ? DEFAULT_TEXT : normalize(value)
      end

      # true, if the project defines its own environments
      def custom?(project)
        !!project && DeploymentSetting.custom?(project)
      end

      # Ordered environments of a text, one per line - the step "Code" and invalid lines are ignored (the settings
      # forms mark them), environments without a color get the default color of their position.
      #
      # @return [Array<Environment>]
      def parse(text)
        environments = normalize(text).split("\n").filter_map { |line| parse_line(line) }.uniq(&:key)
        environments.each_with_index { |environment, index| environment.color ||= default_color(index, environments.size) }
      end

      # the text with the former lines ("production = Live") converted to deployment lines
      def normalize(text)
        text.to_s.split(/\r?\n/).map { |line| convert_legacy(line) || line }.join("\n")
      end

      # @return [Code] the step "Code" of a text (the first code line) - without one: the default label and color
      def parse_code(text)
        match = normalize(text).split("\n").lazy.filter_map { |line| FORMAT.match(line) }.find { |line_match| line_match[3] }
        Code.new(match && match[4].presence, (match && color(match[5])) || CODE_COLOR)
      end

      # @return [Environment, nil] nil for the step "Code", empty, comment and invalid lines (color nil without a
      #   color in the line)
      def parse_line(line)
        match = FORMAT.match(line.to_s)
        return unless match && match[1]

        Environment.new(match[1], match[2], match[4].presence || match[2].capitalize, color(match[5]))
      end

      # the line of an environment - "<type> | <value> | <label> | <color>" - or of the step "Code":
      # "code | | <label> | <color>"
      def line(step)
        return [CODE_TYPE, '', step.label, step.color].join(' | ') if step.is_a?(Code)

        [step.type, step.value, step.label, step.color].join(' | ')
      end

      # the lines of a pipeline: the step "Code" first, then the environments
      def text(code, environments)
        ([code] + environments).map { |step| line(step) }.join("\n")
      end

      # @return [String, nil] hex color of a color name (COLORS) or of '#rrggbb'
      def color(value)
        value = value.to_s.strip
        COLORS[value] || (value.match?(COLOR_FORMAT) ? value.downcase : nil)
      end

      # the color of an environment without a color: by position, the last one is green
      def default_color(index, count)
        COLORS[index == count - 1 ? LAST_COLOR : DEFAULT_COLORS[index % DEFAULT_COLORS.size]]
      end

      private

      def convert_legacy(line)
        return if line.match?(FORMAT) || line.match?(IGNORED)

        match = LEGACY_FORMAT.match(line)
        match && ['deployment', match[1], match[2].presence || match[1].capitalize].join(' | ')
      end
    end
  end
end
