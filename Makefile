# vim: set fenc=utf8 ffs=unix ft=make list noet sw=2 ts=2 tw=100:
SHELL = /bin/zsh
.ONESHELL:

LUA_FILES := $(shell find . -name '*.lua' -print)

help: ## Display all Makfile targets
	@grep -E '^.*[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| sort \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

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

# Spoons that live here as source rather than as SpoonInstall downloads. Keep this list in
# sync with the !Spoons/*.spoon negations in .gitignore -- both encode the same fact, and
# clean is destructive, so a Spoon missing from here is a Spoon it deletes.
KEEP_SPOONS := SpoonInstall BatteryMonitor ClipboardHistory DeminimizeWindow FocusBorder PinnedWindows SummonWindow

clean: ## Remove SpoonInstall-managed Spoon downloads
	find ./Spoons -mindepth 1 -maxdepth 1 -type d \
		$(foreach spoon,$(KEEP_SPOONS),-not -name '$(spoon).spoon') \
		-exec rm -rf {} +
