# frozen_string_literal: true

# Read-only view over Redmine's +changeset_parents+ join table (the commit DAG).
#
# Redmine core exposes the parent/child edges only through +Changeset+'s
# +has_and_belongs_to_many :parents/:children+ associations. Walking the graph
# efficiently (batched frontier queries, +pluck+) is much cleaner with a real
# model, so +Deployment#changesets+ uses this to compute the +from..to+ commit
# range from the database.
class ChangesetParent < ApplicationRecord
  self.table_name = "#{table_name_prefix}changeset_parents#{table_name_suffix}"
end
