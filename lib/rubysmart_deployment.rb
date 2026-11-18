base_path = File.dirname(__FILE__)

%w[
rubysmart_deployment/patches/project_patch
rubysmart_deployment/patches/repository_patch
rubysmart_deployment/patches/repository_git_patch
rubysmart_deployment/patches/changeset_patch
rubysmart_deployment/patches/issue_patch
rubysmart_deployment/patches/application_helper_patch
rubysmart_deployment/patches/queries_helper_patch
rubysmart_deployment/patches/issues_helper_patch
rubysmart_deployment/patches/issues_controller_patch
rubysmart_deployment/patches/projects_helper_patch
rubysmart_deployment/patches/issue_query_patch
rubysmart_deployment/patches/setting_patch
rubysmart_deployment/hooks/views_layouts_hook
].each { |file| require(base_path + '/' + file) }