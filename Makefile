MAKEFILES:=$(shell find . -mindepth 5 -name Makefile -type f)
DIRS:=$(foreach m,$(MAKEFILES),$(realpath $(dir $(m))))

all: install $(DIRS)

install:
	git submodule update --init --recursive

$(DIRS): install
	find $@ -name '*.tar.gz' -print -exec tar xzvf {} \;

deps: ## Install Lua formatter via luarocks
	luarocks install --server=https://luarocks.org/dev luaformatter

format:
	@find . -name '*.lua' -print -exec \
		lua-format \
		--config .lua_format.yml \
		--in-place \
		-- {} \;
	# @find . \
	# 	-name '*.lua' \
	# 	-print \
	# 	-exec stylua -f $$PWD/.stylua.toml  {} \;
	#
.PHONY: all install $(DIRS)
