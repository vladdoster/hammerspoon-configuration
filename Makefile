help: ## Display all Makfile targets
	@grep -E '^.*[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies (i.e., asm modules)
	git submodule update \
		--init \
		--recursive
	$(info compiling modules)
	find . -mindepth 5 -name Makefile -print -type f \
		| xargs -I{} dirname {} \
		| xargs -I{} make \
			--directory {} \
			--ignore-errors \
			--jobs \
			install
	$(info extracting spoon archives)
	find . -mindepth 5 -name '*tar.gz' -print \
		| xargs -I{} realpath {} \
		| xargs -I{} tar -xvzf {}

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
