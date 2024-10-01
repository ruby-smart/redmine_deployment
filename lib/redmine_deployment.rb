base_path = File.dirname(__FILE__)

%w[
redmine_deployment/patches/project_patch
redmine_deployment/patches/repository_patch
redmine_deployment/patches/changeset_patch
redmine_deployment/patches/application_helper_patch
redmine_deployment/patches/queries_helper_patch
redmine_deployment/hooks/views_layouts_hook
].each { |file| require(base_path + '/' + file) }