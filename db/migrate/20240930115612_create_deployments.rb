class CreateDeployments < Rails.version < '5.1' ? ActiveRecord::Migration : ActiveRecord::Migration[4.2]
  def up
    create_table :deployments do |t|
      t.integer :project_id, null: false
      t.integer :repository_id, null: false
      t.integer :author_id, null: false

      t.string :from_revision
      t.string :to_revision

      t.string :environment
      t.text :servers

      t.string :result

      t.datetime :created_on
    end

    add_index :deployments, :project_id
    add_index :deployments, :repository_id
    add_index :deployments, :author_id
  end

  def down
    drop_table :deployments
  end
end