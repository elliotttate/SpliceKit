# Makefile for com.splicekit.transition-alignment
#
# Usage:
#   make           — compile plugin.dylib into build/
#   make install   — compile + copy into ~/Library/Application Support/SpliceKit/plugins/
#   make clean     — remove build artefacts

PLUGIN_ID   = com.splicekit.transition-alignment
PLUGIN_ROOT = $(shell pwd)
REPO_ROOT   = $(PLUGIN_ROOT)/../../..
SRC         = src/TransitionAlignment.m
DYLIB       = build/plugin.dylib
INSTALL_DIR = $(HOME)/Library/Application Support/SpliceKit/plugins/$(PLUGIN_ID)

CC       = clang
ARCHS    = -arch arm64 -arch x86_64
MIN_VER  = -mmacosx-version-min=14.0
CFLAGS   = -O2 -fvisibility=hidden -fobjc-arc \
            -I$(REPO_ROOT)/Sources \
            $(ARCHS) $(MIN_VER)
LDFLAGS  = -dynamiclib -undefined dynamic_lookup \
            -framework Foundation -framework AppKit \
            $(ARCHS) $(MIN_VER)

.PHONY: all install clean

all: $(DYLIB)

$(DYLIB): $(SRC) $(REPO_ROOT)/Sources/SpliceKitPluginAPI.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	@echo "Built $(DYLIB)"

install: $(DYLIB)
	@mkdir -p "$(INSTALL_DIR)"
	cp -f $(DYLIB)    "$(INSTALL_DIR)/plugin.dylib"
	cp -f plugin.json "$(INSTALL_DIR)/plugin.json"
	@echo "Installed $(PLUGIN_ID) → $(INSTALL_DIR)"
	@echo "Restart FCP (or hot-reload via debug_load_plugin) to activate."

clean:
	rm -rf build
