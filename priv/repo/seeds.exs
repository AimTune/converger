# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# In a release (no Mix), use:
#
#     bin/converger eval "Converger.Release.seed_admin()"
#
# Creates the initial super_admin when no admin user exists. Set ADMIN_EMAIL
# and ADMIN_PASSWORD to choose the credentials; without ADMIN_PASSWORD a
# random password is generated, printed once, and must be changed at the
# first login.

Converger.Accounts.bootstrap_super_admin(
  email: System.get_env("ADMIN_EMAIL"),
  password: System.get_env("ADMIN_PASSWORD")
)
|> Converger.Release.report_seed_admin()
