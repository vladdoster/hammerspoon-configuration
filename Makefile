
MAKEFILES:=$(shell find . -mindepth 5 -name Makefile -type f)
DIRS:=$(foreach m,$(MAKEFILES),$(realpath $(dir $(m))))

.PHONY: all
all: $(DIRS)

.PHONY: install
install:
	git submodule update --init --recursive

.PHONY: $(DIRS)
$(DIRS): install
	$(MAKE) -C $@ install-lua
	find $@ -name '*tar.gz' -print -exec tar xzvf {} \;

deps: ## Install Lua formatter via luarocks
	luarocks install --server=https://luarocks.org/dev luaformatter

fmt: ## Format Lua files
	@find . -name '*.lua' -print -exec \
	lua-format \
		--config .lua_format.yml \
		--in-place \
		-- {} \;
