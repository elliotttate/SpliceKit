# Makefile for com.splicekit.undo-history-ui
#
# Usage:
#   make           — compile plugin.dylib into build/
#   make install   — compile + copy into ~/Library/Application Support/SpliceKit/plugins/
#   make clean     — remove build artefacts

PLUGIN_ID   = com.splicekit.undo-history-ui
PLUGIN_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT   := $(abspath $(PLUGIN_ROOT)/../../..)
SRC         = $(PLUGIN_ROOT)/src/UndoHistoryUI.m
DYLIB       = $(PLUGIN_ROOT)/build/plugin.dylib
INSTALL_DIR = $(HOME)/Library/Application Support/SpliceKit/plugins/$(PLUGIN_ID)

CC       = clang
ARCHS    = -arch arm64 -arch x86_64
MIN_VER  = -mmacosx-version-min=14.0
CFLAGS   = -O2 -fvisibility=hidden -fobjc-arc \
            -I$(REPO_ROOT)/Sources \
            $(ARCHS) $(MIN_VER)
LDFLAGS  = -dynamiclib -undefined dynamic_lookup \
            -framework Foundation -framework AppKit -framework CoreMedia \
            $(ARCHS) $(MIN_VER)

.PHONY: all install clean

all: $(DYLIB)

$(DYLIB): $(SRC) $(REPO_ROOT)/Sources/SpliceKitPluginAPI.h
	@mkdir -p "$(PLUGIN_ROOT)/build"
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	@echo "Built $(DYLIB)"

install: $(DYLIB)
	@mkdir -p "$(INSTALL_DIR)"
	cp -f $(DYLIB)    "$(INSTALL_DIR)/plugin.dylib"
	cp -f "$(PLUGIN_ROOT)/plugin.json" "$(INSTALL_DIR)/plugin.json"
	@echo "Installed $(PLUGIN_ID) → $(INSTALL_DIR)"
	@echo "Restart FCP to activate."

clean:
	rm -rf "$(PLUGIN_ROOT)/build"
