base_path = File.dirname(__FILE__)

%w[
redmine_deployment/patches/project_patch
redmine_deployment/patches/repository_patch
redmine_deployment/patches/application_helper_patch
redmine_deployment/patches/queries_helper_patch
].each { |file| require(base_path + '/' + file) }