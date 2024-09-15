# vim: set fenc=utf8 ffs=unix ft=make list noet sw=2 ts=2 tw=100:
SHELL = /bin/zsh
.ONESHELL:

LUA_FILES := $(shell find . -name '*.lua' -print)

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

format: ## Run stylua
	stylua \
		--call-parentheses Always \
		--collapse-simple-statement ConditionalOnly \
		--column-width 120 \
		--indent-type Spaces \
		--indent-width 2 \
		--line-endings Unix \
		--no-editorconfig \
		--quote-style AutoPreferDouble \
		--sort-requires \
		--verbose \
		$(LUA_FILES)

clean: ## Remove artifacts
	git submodule deinit \
		--all \
		--force
	find ./Spoons/* -not \( -name "asm*" -o -name "SpoonInstall.spoon" \) -type d -exec rm -rvf {} +
