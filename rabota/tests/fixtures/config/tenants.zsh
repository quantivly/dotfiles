# Fixture tenants file for the rabota suite (DO-665). Read by the REAL
# scripts/machines-render, not by a stub: a stub is a claim about the tool.
CLAUDE_TENANT_MACHINE_OWNED=( quantivly-0 "dev (EC2)" )
CLAUDE_TENANT_MACHINE_ID=(    quantivly-0 dev )

# Routing tables (DO-773). rabota gave up its own [[route]] table and default, so this file is
# now the only thing that can answer "which tenant owns this directory" — including for the rows
# that run the REAL scripts/tenant-route. The default is what a directory with no GitHub remote
# gets, and it names a tenant this fixture overlay actually has a toml for; a pool per tenant is
# required, because the resolver refuses a tenant that has none.
CLAUDE_TENANT_ROUTES=( "fixture-org=quantivly" )
CLAUDE_TENANT_PATH_ROUTES=()
CLAUDE_TENANT_DEFAULT=personal
CLAUDE_TENANT_POOL=( quantivly "quantivly-1" toysim "toysim-0" personal "personal-0" )
