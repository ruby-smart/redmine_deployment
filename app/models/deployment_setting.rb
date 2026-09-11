# frozen_string_literal: true

# The settings of the plugin (Setting.plugin_redmine_deployment) - like ContactsSetting of redmine_contacts:
#
#   'environments' => the central deployment pipeline (text, see RedmineDeployment::Environments)
#   'projects'     => { <project id> => { 'custom' => '1', 'environments' => <the project's own pipeline> } }
#
# A project uses its own pipeline, if 'custom' is '1' - otherwise the central one.
class DeploymentSetting
  class << self
    # @return [Hash] the plugin settings (string keys)
    def settings
      (Setting.plugin_redmine_deployment.presence || {}).to_h.stringify_keys
    end

    # the setting +name+ - of the project, if given (like ContactsSetting[name, project])
    def [](name, project = nil)
      project_id = project_id_of(project)
      return settings[name.to_s] unless project_id

      project_settings(project_id)[name.to_s]
    end

    # sets the setting +name+ - of the project, if given
    def []=(name, project, value)
      update_project(project, name => value) if project_id_of(project)
      store(settings.merge(name.to_s => value)) unless project_id_of(project)
    end

    # @return [Hash] the settings of the project (string keys, empty without settings)
    def project_settings(project)
      project_id = project_id_of(project)
      projects   = projects_hash
      (projects[project_id] || projects[project_id.to_s] || {}).to_h.stringify_keys
    end

    # merges +values+ into the settings of the project
    def update_project(project, values)
      project_id = project_id_of(project)
      projects   = projects_hash.except(project_id.to_s)
      projects[project_id] = project_settings(project_id).merge(values.to_h.stringify_keys)
      store(settings.merge('projects' => projects))
    end

    # removes the settings of the project (e.g. when it is deleted)
    def delete_project(project)
      project_id = project_id_of(project)
      projects   = projects_hash
      return unless projects.key?(project_id) || projects.key?(project_id.to_s)

      store(settings.merge('projects' => projects.except(project_id, project_id.to_s)))
    end

    # true, if the project uses its own deployment pipeline
    def custom?(project)
      self['custom', project].to_s == '1'
    end

    private

    def projects_hash
      value = settings['projects']
      value.is_a?(Hash) ? value.to_h : {}
    end

    def project_id_of(project)
      project.is_a?(Project) ? project.id : project.presence&.to_i
    end

    def store(values)
      Setting.plugin_redmine_deployment = values
    end
  end
end
