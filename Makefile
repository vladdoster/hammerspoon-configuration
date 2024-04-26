# vim: set fenc=utf8 ffs=unix ft=make list noet sw=2 ts=2 tw=100:
SHELL = /bin/zsh
.ONESHELL:

help: ## Display all Makfile targets
	@grep -E '^.*[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

dependencies:
	git submodule update --init --recursive

compile: ## Install dependencies (i.e., asm modules)
	$(info compiling modules)
	zsh --extendedglob -c 'for mk_dir in **/(*/)#Makefile(:h); make -C$${mk_dir} -Bikj8 all install_everything docs install'

.PHONY: compile

install-luaformatter: ## Install luaformatter via luarocks
	luarocks install \
		--server https://luarocks.org/dev \
		luaformatter

format: ## Run lua-formatter using .lua_format.yml config
	stylua \
		--call-parentheses Input \
		--collapse-simple-statement Always \
		--column-width 120 \
		--glob **/*.lua \
		--indent-type Spaces \
		--line-endings Unix \
		--quote-style AutoPreferSingle \
		--verbose

clean: ## Remove artifacts
	git submodule deinit \
		--all \
		--force
	find ./Spoons/* -not \( -name "asm*" -o -name "SpoonInstall.spoon" \) -type d -exec rm -rvf {} +
