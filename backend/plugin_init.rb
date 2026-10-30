require_relative '../lib/alma_integrations'

# Backend wiring for the Alma integrations plugin.
#
# Database footprint
# ------------------
# This plugin adds no migrations and no tables. By default it also writes
# nothing permanent of its own: the permission below is declared with
# `:implied_by`, which ArchivesSpace keeps in an in-memory array and resolves at
# query time rather than storing (see Permission.define -- it returns before
# touching the database when `:implied_by` is given). Removing the plugin
# removes the permission with it, leaving nothing behind to clean up.
#
# Setting AppConfig[:alma_standalone_permission] = true trades that for a real
# row in `permission`, which is what you need if the permission has to be
# grantable to a group independently of Repository Manager. ArchivesSpace never
# removes permission rows, so that choice is undone by hand:
#
#   DELETE FROM group_permission WHERE permission_id =
#     (SELECT id FROM permission WHERE permission_code = 'update_alma_records');
#   DELETE FROM permission WHERE permission_code = 'update_alma_records';
#
# (group_permission has no ON DELETE CASCADE, so it must go first.)
Permission.define(
  'update_alma_records',
  'Push ArchivesSpace records to the Alma catalogue in bulk',
  if AppConfig.has_key?(:alma_standalone_permission) && AppConfig[:alma_standalone_permission]
    { :level => 'repository' }
  else
    { :level => 'repository', :implied_by => 'manage_repository' }
  end
)
