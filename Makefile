NVIM ?= nvim
DEPS := .deps
PLENARY_DIR ?= $(DEPS)/plenary.nvim
PARSER_DIR ?= $(DEPS)/parsers
TS_FSTAR_DIR ?= $(DEPS)/tree-sitter-fstar
TS_FSTAR_REV := f5aca8ce0122f0ac10eaeb6f3081382d59d294f2
SPEC ?= tests/spec
TIMEOUT ?= 120000

.PHONY: test test-integration test-live copilot-helper test-copilot-helper deps parsers clean-deps

copilot-helper:
	cargo build --locked --release --manifest-path tools/copilot/Cargo.toml

test-copilot-helper:
	cargo test --locked --manifest-path tools/copilot/Cargo.toml

test: deps parsers
	PLENARY_DIR=$(PLENARY_DIR) PARSER_DIR=$(PARSER_DIR) $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('$(SPEC)', { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = $(TIMEOUT) })"

# Runs against a real fstar.exe (skipped when none is on PATH).
test-integration: deps parsers
	$(MAKE) test SPEC=tests/integration TIMEOUT=900000

# Real agent + real fstar.exe; costs tokens or Copilot premium requests.
# NEOSTAR_LIVE_RUNNER: claude (default) or copilot. NEOSTAR_LIVE_MODEL: the model
# (default haiku for claude; Copilot's own default for copilot), e.g.
#   NEOSTAR_LIVE_RUNNER=copilot NEOSTAR_LIVE_MODEL=mai-code-2-flash make test-live
test-live: deps parsers
	NEOSTAR_LIVE_AGENT=1 $(MAKE) test SPEC=tests/live TIMEOUT=900000

deps: $(PLENARY_DIR)

$(PLENARY_DIR):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

$(TS_FSTAR_DIR):
	git clone https://github.com/FStarLang/tree-sitter-fstar $(TS_FSTAR_DIR)
	git -C $(TS_FSTAR_DIR) checkout --quiet $(TS_FSTAR_REV)

parsers: $(PARSER_DIR)/parser/fstar.so $(PARSER_DIR)/parser/pulse.so

$(PARSER_DIR)/parser/fstar.so: | $(TS_FSTAR_DIR)
	mkdir -p $(PARSER_DIR)/parser
	cc -O2 -shared -fPIC -I$(TS_FSTAR_DIR)/src -o $@ $(TS_FSTAR_DIR)/src/parser.c $(TS_FSTAR_DIR)/src/scanner.c

$(PARSER_DIR)/parser/pulse.so: | $(TS_FSTAR_DIR)
	mkdir -p $(PARSER_DIR)/parser
	cc -O2 -shared -fPIC -I$(TS_FSTAR_DIR)/pulse/src -o $@ $(TS_FSTAR_DIR)/pulse/src/parser.c $(TS_FSTAR_DIR)/pulse/src/scanner.c

clean-deps:
	rm -rf $(DEPS)
