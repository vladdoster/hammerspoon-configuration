MAKEFILES:=$(shell find . -mindepth 5 -name Makefile -type f)
DIRS:=$(foreach m,$(MAKEFILES),$(realpath $(dir $(m))))

help: ## Display all Makfile targets
	@grep -E '^.*[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

all: install $(DIRS)

install: ## Install dependencies (i.e., asm modules)
	git submodule update --init --recursive

format/lua-format: ## Format Lua files in-place via lua-formatter
  ifeq (, $(shell which lua-format))
  $(error "No lua-format in \$(PATH), consider doing apt-get install lzop")
  endif
	find . -name '*.lua' -maxdepth 2 -print -exec \
		lua-format \
		--config $$(PWD)/.lua_format.yml \
		--in-place \
		-- {} \;

format/stylua: ## Format Lua files in-place via Stylua
  ifeq (, $(shell which stylua))
  $(error "No stylua in \$(PATH), consider doing apt-get install lzop")
  endif
	find . -name '*.lua' -maxdepth 2 -print -exec \
		stylua \
		-- {} \;

$(DIRS): install ## Extracts module archives
	find $@ -name '*.tar.gz' -print -exec tar xzvf {} \;
