# frozen_string_literal: true

# The changesets of a deployment - its commit range from_revision..to_revision - stored once (in the background, see
# Deployment#resolve_changesets!) instead of walking the commit graph on every request.
class CreateDeploymentChangesets < ActiveRecord::Migration[5.2]
  def change
    create_table :deployment_changesets do |t|
      t.integer :deployment_id, :null => false
      t.integer :changeset_id, :null => false
    end
    add_index :deployment_changesets, [:deployment_id, :changeset_id], :unique => true, :name => :deployment_changesets_ids
    add_index :deployment_changesets, :changeset_id

    # when the changesets were resolved (nil: not yet) and why the last attempt could not resolve them
    add_column :deployments, :changesets_resolved_at, :datetime
    add_column :deployments, :changesets_error, :string
    add_index :deployments, :changesets_resolved_at
  end
end
