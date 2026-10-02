# frozen_string_literal: true

namespace :redmine do
  namespace :deployment do
    desc <<~END_DESC
      Resolves the changesets of the deployments - the commit range from_revision..to_revision of each deployment,
      stored in deployment_changesets (see Deployment#resolve_changesets!) - for the pending deployments: logged
      before their revisions were fetched into Redmine, or logged before the plugin stored the ranges at all (the
      backfill after the update to 1.4). Run it after redmine:fetch_changesets.

      Options:
        FORCE=1               resolve every deployment again (e.g. after a repository was reloaded)
        PROJECT=identifier    the deployments of one project only
        DEPLOYMENT=id         one deployment only

      Example:
        rake redmine:deployment:resolve_changesets RAILS_ENV="production"
        rake redmine:deployment:resolve_changesets PROJECT=ri-app FORCE=1 RAILS_ENV="production"
    END_DESC
    task :resolve_changesets => :environment do
      scope = Deployment.all
      scope = scope.where(:project_id => Project.find_by!(:identifier => ENV['PROJECT']).id) if ENV['PROJECT'].present?
      scope = scope.where(:id => ENV['DEPLOYMENT'].to_i) if ENV['DEPLOYMENT'].present?
      scope = scope.changesets_pending unless %w[1 true yes].include?(ENV['FORCE'].to_s.downcase)

      started = Time.now
      summary = Deployment.resolve_changesets!(scope)

      puts "#{summary[:resolved]} deployment(s) resolved in #{(Time.now - started).round(1)}s"
      summary[:unresolved].each do |reason, count|
        puts "#{count} deployment(s) not resolved: #{reason}"
      end
    end
  end
end
