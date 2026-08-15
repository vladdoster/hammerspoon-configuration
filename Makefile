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
KEEP_SPOONS := SpoonInstall BatteryMonitor ClipboardHistory DeminimizeWindow FocusBorder PinnedWindows SummonWindow VolumeControl

# SpoonInstall is vendored upstream, so its docs.json stays as shipped
DOC_SPOONS := $(filter-out SpoonInstall,$(KEEP_SPOONS))

clean: ## Remove SpoonInstall-managed Spoon downloads
	find ./Spoons -mindepth 1 -maxdepth 1 -type d \
		$(foreach spoon,$(KEEP_SPOONS),-not -name '$(spoon).spoon') \
		-exec rm -rf {} +

# Continuations, not .ONESHELL: that needs GNU Make 3.82 and macOS ships 3.81
docs: ## Regenerate first-party Spoon docs.json with deterministic key order
	@command -v hs >/dev/null 2>&1 \
		|| { echo 'error: hs not found; Hammerspoon must be running with require("hs.ipc")' >&2; exit 1; }
	@command -v python3 >/dev/null 2>&1 \
		|| { echo 'error: python3 not found; it is what sorts the generated JSON' >&2; exit 1; }
	@for spoon in $(DOC_SPOONS); do \
		dir="$(CURDIR)/Spoons/$$spoon.spoon"; \
		tmp="$$(mktemp -t docsjson)"; \
		hs -c "local ok, out = pcall(hs.doc.builder.genJSON, [[$$dir]]) ; if not ok then return end ; local f = io.open([[$$tmp]], 'w') ; if not f then return end ; f:write(out) ; f:close()" >/dev/null 2>&1; \
		if [ ! -s "$$tmp" ]; then \
			rm -f "$$tmp"; \
			echo "error: genJSON produced nothing for $$spoon" >&2; \
			exit 1; \
		fi; \
		python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); open(sys.argv[2],"w",encoding="utf-8").write(json.dumps(d,indent=2,sort_keys=True,ensure_ascii=False)+"\n")' "$$tmp" "$$dir/docs.json"; \
		rm -f "$$tmp"; \
		echo "regenerated $$spoon.spoon/docs.json"; \
	done
