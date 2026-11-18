# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # The plugin settings form (Administration » Plugins) posts the central settings only - it would drop the
    # settings of the projects ('projects', see DeploymentSetting). They are kept, if the new value has none.
    module SettingPatch
      def plugin_rubysmart_deployment=(value)
        value = (value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h).stringify_keys
        unless value.key?('projects')
          projects = DeploymentSetting.settings['projects']
          value['projects'] = projects if projects.present?
        end
        super(value)
      end
    end
  end
end

unless Setting.singleton_class.include?(RubysmartDeployment::Patches::SettingPatch)
  Setting.singleton_class.prepend(RubysmartDeployment::Patches::SettingPatch)
end
