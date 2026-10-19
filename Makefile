# vcssign developer tasks (impl/knowledge/testing/ §4).
#
# On Linux/macOS use `make`.  git-bash on Windows usually has no make, so
# the scripts are the real entry points (`sh scripts/run_tests.sh`) — this
# file only adds the dependency wiring (fixtures, tools) and the CI targets.
SHELL := bash

# deps/ tools carry the platform suffix scripts/tools.sh downloaded them with.
EXE := $(if $(filter Windows_NT,$(OS)),.exe,)
FILTER ?=
STYLUA ?= deps/stylua$(EXE)
LUACHECK ?= deps/luacheck$(EXE)
LUA_FILES := $(shell git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua')

.DEFAULT_GOAL := help

.PHONY: help
help: ## list the targets
	@grep -hE '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## / - /' | sort

.PHONY: tools
tools: ## download stylua + luacheck into deps/ (pinned, idempotent)
	sh scripts/tools.sh

.PHONY: fixtures
fixtures: ## create the test repositories under temp/ (idempotent)
	sh scripts/make_test_repos.sh

.PHONY: test
test: fixtures tools ## run the specs (FILTER=renderer_spec for just one)
	sh scripts/run_tests.sh $(FILTER)

.PHONY: format
format: tools ## rewrite lua/ and test/ with stylua
	$(STYLUA) $(LUA_FILES)

.PHONY: format-check
format-check: tools ## fail when a file is not stylua-formatted (CI)
	$(STYLUA) --check $(LUA_FILES)

.PHONY: lint
lint: tools ## luacheck lua/, test/ and scripts/
	$(LUACHECK) .
