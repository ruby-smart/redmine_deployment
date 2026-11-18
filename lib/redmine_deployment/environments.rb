# frozen_string_literal: true

require 'timeout'

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
  # * tag: part of a tag of the repository (e.g. "tag | /^v\d+\./ | Release")
  # * deployment: a successful deployment of the environment (e.g. "deployment | production | Live")
  #
  # The value can be dynamic (see Environment#target) - it is resolved for each issue:
  # * wildcard "*": any characters, e.g. "branch | feature/*" (merged into any feature branch)
  # * placeholders "{%object.attribute%}": an attribute of the issue (PLACEHOLDER_OBJECTS), e.g.
  #   "branch | feature/{%issue.id%}-*" or "deployment | review-{%tracker.name%}"
  # * regular expression "/<regexp>/" (case-insensitive: "/<regexp>/i"), e.g. "branch | /^(develop|main)$/" or
  #   "branch | /^(feature|bugfix)\/{%issue.id%}-/i" - not anchored (use ^ and $), it may contain "|" and "/";
  #   placeholders are inserted as literal text
  # Dynamic values match case-insensitively (regular expressions only with "i"), a placeholder without a value (e.g.
  # no category) never matches.
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
    TYPES     = %w[branch tag deployment].freeze
    CODE_TYPE = 'code'
    # One line: "<type> | <branch or environment> | <label> | <color>" or "code | | <label> | <color>" (without a
    # value) - the label and the color (COLORS name or '#rrggbb') are optional. A regular expression ("/.../") may
    # contain "|". The settings forms check every row with this pattern (JS), so it is JS-compatible.
    PATTERN = '^\s*(?:(branch|tag|deployment)\s*\|\s*(/.+?/i?|[^|\s](?:[^|]*[^|\s])?)|(code)\s*\|)\s*' \
              "(?:\\|\\s*([^|]*?)\\s*(?:\\|\\s*(#[0-9a-fA-F]{6}|#{COLORS.keys.join('|')})\\s*)?)?$"
    FORMAT  = Regexp.new(PATTERN)
    # empty lines and comments ("# ...") are ignored
    IGNORED = /\A\s*(#.*)?\z/.freeze
    # the former format: "<deployment environment> = <label>"
    LEGACY_FORMAT = /\A\s*([^|=:#\s][^|=:]*?)\s*(?:[=:]\s*([^|]*?))?\s*\z/.freeze

    WILDCARD = '*'
    # a regular expression as value: "/<regexp>/" or "/<regexp>/i" (case-insensitive) - JS-compatible (settings forms)
    REGEXP_PATTERN = '^/(.+)/(i?)$'
    REGEXP_FORMAT  = Regexp.new(REGEXP_PATTERN)
    # the maximum time of one match of a regular expression (Ruby >= 3.2) - a slow one (ReDoS) does not match
    REGEXP_TIMEOUT = 0.1
    # the maximum time all matches of the regular expressions of the settings may take together, per deploy status
    # (i.e. per request - see MatchBudget): a slow one costs at most this much, not REGEXP_TIMEOUT per branch / tag
    REGEXP_BUDGET = 1.0
    # "{%issue.id%}" - object and attribute
    PLACEHOLDER = /\{%\s*(\w+)\.(\w+)\s*%\}/.freeze
    # a value split into its placeholders, its wildcards and the literal text between them
    TOKENS = /(\{%\s*\w+\.\w+\s*%\}|\*)/.freeze
    # a regular expression split into its placeholders and the regexp source between them
    PLACEHOLDER_TOKENS = /(\{%\s*\w+\.\w+\s*%\})/.freeze
    # the objects of the placeholders: the association of the issue (nil: the issue itself) - their attributes are
    # the columns of the record
    PLACEHOLDER_OBJECTS = {
      'issue' => nil,
      'tracker' => :tracker,
      'project' => :project,
      'status' => :status,
      'priority' => :priority,
      'category' => :category,
      'version' => :fixed_version,
      'author' => :author,
      'assigned_to' => :assigned_to
    }.freeze
    # users and groups (author, assigned_to): only these attributes - no password hashes etc.
    PRINCIPAL_ATTRIBUTES = %w[id login firstname lastname name].freeze

    # the value of an environment resolved for an issue: text (placeholders replaced, e.g. for the pipeline popup) and
    # the pattern the branch or deployment environment has to match - custom: a regular expression of the settings
    # ("/.../" - any pattern, see MatchBudget), not one built from a literal value or wildcards (linear)
    Target = Struct.new(:text, :regexp, :custom) do
      def match?(name)
        regexp.match?(name.to_s)
      rescue RegexpError # Regexp::TimeoutError
        false
      end
    end

    # The time the regular expressions of the settings ("/.../" - Target#custom) may take to match, all together: one
    # deploy status (one request) matches them against every branch / tag / deployment environment, for every issue
    # target - a slow regular expression (ReDoS) would cost REGEXP_TIMEOUT each time. Once the budget is used up,
    # they match nothing any more (logged once). On Ruby < 3.2 (no Regexp timeout) a single match is aborted when the
    # budget runs out (Timeout). Targets of literal values and wildcards are linear and match outside the budget.
    class MatchBudget
      attr_reader :remaining

      # @param [Numeric] seconds
      def initialize(seconds = REGEXP_BUDGET)
        @remaining = seconds.to_f
      end

      def exhausted?
        remaining <= 0
      end

      # @param [Target] target
      # @param [Array<String>] names
      # @return [Array<String>] the names matching the target - none, once the budget is used up
      def select(target, names)
        return names.select { |name| target.match?(name) } unless target.custom
        return [] if exhausted?

        started = clock
        begin
          within(remaining) do
            names.select do |name|
              raise Timeout::Error if clock - started > remaining

              target.match?(name)
            end
          end
        rescue Timeout::Error
          @remaining = 0
          []
        ensure
          @remaining -= clock - started
          warn(target) if exhausted?
        end
      end

      private

      # the block - aborted after +seconds+, if a single match can't be limited by Regexp (Ruby < 3.2)
      def within(seconds, &block)
        Environments.regexp_timeout? ? yield : Timeout.timeout(seconds, &block)
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def warn(target)
        return if @warned

        @warned = true
        Rails.logger.warn("RedmineDeployment::Environments: the regular expressions of the pipeline took more than " \
                          "#{REGEXP_BUDGET}s (#{target.text}) - they match nothing for the rest of the request")
      end
    end

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

      def tag?
        type == 'tag'
      end

      # true for a branch or a tag: reached by the ancestors of a commit (the head of the branch, the commit of the tag)
      def ref?
        branch? || tag?
      end

      def deployment?
        type == 'deployment'
      end

      # true, if the value is a regular expression or has wildcards or placeholders
      def dynamic?
        regexp? || value.include?(WILDCARD) || placeholders?
      end

      # true, if the value is a regular expression ("/.../")
      def regexp?
        value.match?(REGEXP_FORMAT)
      end

      def placeholders?
        value.match?(PLACEHOLDER)
      end

      # @param [Issue] issue
      # @return [Target, nil] the value resolved for the issue - nil: a placeholder has no value (never reached)
      def target(issue)
        Environments.resolve(value, issue)
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

      # @return [Environment, nil] nil for the step "Code", empty, comment and invalid lines (also an invalid regular
      #   expression; color nil without a color in the line)
      def parse_line(line)
        match = FORMAT.match(line.to_s)
        return unless match && match[1] && valid_value?(match[2])

        label = match[4].presence || (match[2].match?(REGEXP_FORMAT) ? match[2] : match[2].capitalize)
        Environment.new(match[1], match[2], label, color(match[5]))
      end

      # true, if a single match of a regular expression can be limited (Regexp timeout, Ruby >= 3.2)
      def regexp_timeout?
        Regexp.respond_to?(:timeout)
      end

      # false for a regular expression Ruby can't compile (its placeholders count as literal text)
      def valid_value?(value)
        regexp = REGEXP_FORMAT.match(value.to_s)
        return true unless regexp

        compile(regexp[1].gsub(PLACEHOLDER, 'x'), regexp[2])
        true
      rescue RegexpError
        false
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

      # The value of an environment for an issue: the placeholders replaced by the attributes of the issue, "*" any
      # characters - literal values match exactly, dynamic ones case-insensitively. The values of the placeholders
      # are literal text (a "*" in a subject is no wildcard).
      #
      # A regular expression ("/.../") is used as it is - only its placeholders are replaced (escaped).
      #
      # @return [Target, nil] nil: a placeholder is unknown or has no value for the issue, an invalid regular expression
      def resolve(value, issue)
        value  = value.to_s
        regexp = REGEXP_FORMAT.match(value)
        return resolve_regexp(regexp[1], regexp[2], issue) if regexp

        text   = +''
        source = +''
        value.split(TOKENS).each do |part|
          if part == WILDCARD
            text << part
            source << '.*'
          else
            match = PLACEHOLDER.match(part) if part.start_with?('{%')
            part  = placeholder_value(issue, match[1], match[2]) if match && match[0] == part
            return if part.nil?

            text << part
            source << Regexp.escape(part)
          end
        end

        dynamic = value.include?(WILDCARD) || value.match?(PLACEHOLDER)
        Target.new(text, compile("\\A#{source}\\z", dynamic ? 'i' : ''))
      end

      # @return [Target, nil] the regular expression with the placeholders replaced by the (escaped) attributes of the
      #   issue - text: "/<regexp>/<flags>" with the attributes as they are
      def resolve_regexp(source, flags, issue)
        text    = +''
        pattern = +''
        source.split(PLACEHOLDER_TOKENS).each do |part|
          match = PLACEHOLDER.match(part) if part.start_with?('{%')
          if match && match[0] == part
            part = placeholder_value(issue, match[1], match[2])
            return if part.nil?

            pattern << Regexp.escape(part)
          else
            pattern << part
          end
          text << part
        end

        Target.new("/#{text}/#{flags}", compile(pattern, flags), true)
      rescue RegexpError
        nil
      end

      # @param [String] flags - 'i': case-insensitive
      # @return [Regexp] with a timeout per match (REGEXP_TIMEOUT), if supported (Ruby >= 3.2)
      def compile(source, flags)
        options = flags == 'i' ? Regexp::IGNORECASE : nil
        return Regexp.new(source, options) unless regexp_timeout?

        Regexp.new(source, options, timeout: REGEXP_TIMEOUT)
      end

      # @return [String, nil] the attribute of the placeholder object of the issue - nil: unknown object or attribute
      #   or no value
      def placeholder_value(issue, object, attribute)
        return unless issue && PLACEHOLDER_OBJECTS.key?(object)

        association = PLACEHOLDER_OBJECTS[object]
        record      = association ? issue.public_send(association) : issue
        value       =
          if record.is_a?(Principal)
            record.public_send(attribute) if PRINCIPAL_ATTRIBUTES.include?(attribute)
          elsif record && record.class.column_names.include?(attribute)
            record.read_attribute(attribute)
          end
        value.to_s.strip.presence
      end

      # @return [Array<Symbol>] the associations of the issues the placeholders of the environments need (to preload)
      def placeholder_associations(environments)
        environments.flat_map { |environment| environment.value.scan(PLACEHOLDER).map { |object, _| PLACEHOLDER_OBJECTS[object] } }.
          compact.uniq
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
