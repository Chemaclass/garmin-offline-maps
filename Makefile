# Offline Maps for Garmin -- build helpers.
#
# Everything here assumes the Connect IQ SDK is installed and `monkeyc` is on
# your PATH. If it is not, point SDK_BIN at the SDK's bin directory:
#
#     make build SDK_BIN=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/current/bin
#
# Quick start:
#     make key                                  # one-off signing key
#     make pack BBOX=-3.75,40.38,-3.65,40.45    # build a map of your area
#     make build && make sim                    # run it in the simulator

SHELL := /bin/bash

DEVICE      ?= venu3

# Homebrew's connectiq cask links monkeyc and monkeydo onto PATH but *not*
# connectiq, the simulator launcher -- so `make sim` cannot rely on PATH the way
# `make build` can. Autodetect the Caskroom SDK instead, newest version last.
# An explicit SDK_BIN= on the command line still wins.
BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
CASK_SDK    := $(lastword $(sort $(wildcard $(BREW_PREFIX)/Caskroom/connectiq/*/connectiq-sdk-mac-*/bin)))
SDK_BIN     ?= $(CASK_SDK)

MONKEYC     := $(if $(SDK_BIN),$(SDK_BIN)/monkeyc,monkeyc)
MONKEYDO    := $(if $(SDK_BIN),$(SDK_BIN)/monkeydo,monkeydo)
SIMULATOR   := $(if $(SDK_BIN),$(SDK_BIN)/connectiq,connectiq)

# The simulator's side-load socket. Kept on its own line: a trailing `#`
# comment ends the value but leaves the spaces before it inside the variable.
SIM_PORT    ?= 1234

KEY         ?= developer_key
BIN         := bin
PRG         := $(BIN)/offline-maps.prg
IQ          := $(BIN)/offline-maps.iq

PYTHON      ?= python3
PACKER      := $(PYTHON) -m mappack
PACK_DIR    := tools/mappack

# --- map pack inputs -------------------------------------------------------
# CITY (looked up by name), BBOX (fetched from Overpass), or INPUT (a local
# .osm / .osm.pbf file). CITY is the one to reach for; the other two are there
# when you want an exact region or already have the data.
CITY        ?=
RADIUS_KM   ?= 6
CITY_INDEX  ?= 0
BBOX        ?=
INPUT       ?=
# With CITY the packer names the pack after the place it found, so leave it
# empty and let it decide. Anything else is "custom" until you say otherwise --
# it used to be "demo" for INPUT, from before `make demo` was its own target,
# so a pack built from a local extract shipped labelled as the demo.
NAME        ?= $(if $(CITY),,custom)
ZOOMS       ?= 12,14,16
SIMPLIFY    ?= 1.0
EXTRA       ?=

.PHONY: help doctor key pack demo build watch sim serve city package test lint clean distclean

help:
	@echo "Targets:"
	@echo "  make key         generate a developer signing key (once)"
	@echo "  make pack        build a map pack   (BBOX=w,s,e,n  or  INPUT=file.osm)"
	@echo "  make demo        rebuild the bundled synthetic demo pack"
	@echo "  make build       compile for DEVICE=$(DEVICE)"
	@echo "  make sim         launch the simulator and side-load the app"
	@echo "  make serve       drive the map in a browser (no SDK needed)"
	@echo "  make package     build the .iq bundle for the Connect IQ store"
	@echo "  make city        build one city's store bundle (CITY=berlin)"
	@echo "  make test        run the packer test suite"
	@echo "  make lint        byte-compile the packer"
	@echo "  make doctor      report which toolchain pieces are missing"
	@echo "  make clean       remove build output"

# --- diagnosis -------------------------------------------------------------
# The four watch-side prerequisites fail with similar-looking errors, so name
# them individually rather than letting monkeyc guess. Checks existence only --
# developer_key is never read.

doctor:
	@echo "== watch app =="
	@printf '  %-20s' "compiler"; \
		if command -v "$(MONKEYC)" >/dev/null 2>&1; then \
			"$(MONKEYC)" --version 2>&1 | head -1; \
		else echo "MISSING   brew install --cask connectiq"; fi
	@printf '  %-20s' "java"; \
		if java -version >/dev/null 2>&1; then java -version 2>&1 | head -1; \
		else echo "MISSING   brew install --cask temurin@21"; fi
	@printf '  %-20s' "simulator"; \
		if [ -x "$(SIMULATOR)" ] || command -v "$(SIMULATOR)" >/dev/null 2>&1; then \
			echo "$(SIMULATOR)"; \
		else echo "MISSING   in the connectiq cask, but not linked onto PATH"; fi
	@printf '  %-20s' "devices"; \
		d="$$HOME/Library/Application Support/Garmin/ConnectIQ/Devices"; \
		if [ -d "$$d" ] && [ -n "$$(ls -A "$$d" 2>/dev/null)" ]; then \
			ls "$$d" | tr '\n' ' '; echo; \
		else echo "MISSING   open SdkManager.app, log in, get venu3 + venu3s"; fi
	@printf '  %-20s' "signing key"; \
		if [ -f "$(KEY)" ]; then echo "present"; else echo "MISSING   make key"; fi
	@echo "== packer =="
	@printf '  %-20s' "python3"; $(PYTHON) --version 2>&1
	@printf '  %-20s' "pillow"; \
		if $(PYTHON) -c "import PIL" 2>/dev/null; then echo "present"; \
		else echo "absent    pip install pillow -- 10 preview tests skip"; fi
	@printf '  %-20s' "osmium"; \
		if $(PYTHON) -c "import osmium" 2>/dev/null; then echo "present"; \
		else echo "absent    pip install osmium -- only for .osm.pbf input"; fi

# --- signing ---------------------------------------------------------------

$(KEY):
	@echo ">> generating $(KEY) (keep it; the store ties your app id to it)"
	openssl genrsa -out $(KEY).pem 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER -in $(KEY).pem -out $(KEY) -nocrypt
	@rm -f $(KEY).pem

key: $(KEY)

# --- map data --------------------------------------------------------------

pack:
ifeq ($(strip $(CITY)$(BBOX)$(INPUT)),)
	$(error set CITY="Madrid", BBOX=west,south,east,north, or INPUT=path/to/region.osm)
endif
	cd $(PACK_DIR) && $(PACKER) \
		$(if $(INPUT),--input "$(abspath $(INPUT))") \
		$(if $(CITY),--city "$(CITY)" --radius-km $(RADIUS_KM) --city-index $(CITY_INDEX)) \
		$(if $(BBOX),--bbox "$(BBOX)") \
		$(if $(NAME),--name "$(NAME)") --zooms "$(ZOOMS)" --simplify $(SIMPLIFY) \
		--out "$(CURDIR)/mapdata/active" \
		--index "$(CURDIR)/source/generated/MapIndex.mc" \
		$(EXTRA)

demo:
	cd $(PACK_DIR) && $(PACKER) --input tests/demo-city.osm --name "Berlin Demo" \
		--zooms 12,14,16 \
		--out "$(CURDIR)/mapdata/active" \
		--index "$(CURDIR)/source/generated/MapIndex.mc"

# --- build -----------------------------------------------------------------

build: $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -f monkey.jungle -o $(PRG) -y $(KEY) -d $(DEVICE) -w
	@ls -lh $(PRG)

# Build and side-load onto a watch on USB. The fast loop: no store upload, no
# review, no phone. See tools/push-watch.sh for what it needs.
watch:
	@tools/push-watch.sh $(DEVICE)

sim: build
	@if nc -z 127.0.0.1 $(SIM_PORT) 2>/dev/null; then \
		echo ">> reusing the running simulator"; \
	else \
		echo ">> starting simulator (leave it running between builds)"; \
		$(SIMULATOR) >/dev/null 2>&1 & \
	fi
	@for i in $$(seq 1 30); do \
		nc -z 127.0.0.1 $(SIM_PORT) 2>/dev/null && break; \
		if [ $$i -eq 30 ]; then \
			echo ">> simulator never opened port $(SIM_PORT)" >&2; exit 1; \
		fi; \
		sleep 1; \
	done
	@echo ">> side-loading $(PRG) as $(DEVICE) -- Ctrl-C detaches, sim keeps running"
	$(MONKEYDO) $(PRG) $(DEVICE)

# --- store listings --------------------------------------------------------
# The map is compiled in, so one listing covers one region. cities.json holds
# each city's own app id and name; see docs/PUBLISHING.md.
#
#   make city             # list the configured cities
#   make city CITY=berlin # -> bin/offline-maps-berlin.iq

city:
	@tools/build-city.sh $(if $(CITY),$(CITY),--list)

package: $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -e -f monkey.jungle -o $(IQ) -y $(KEY) -w -r
	@ls -lh $(IQ)

# --- interactive demo ------------------------------------------------------
# Drives the Python renderer in a browser: pan, zoom, themes, heading-up and
# the real segment budgets. Needs Pillow, needs no SDK, and is the only way to
# *use* the map when the Connect IQ simulator will not run.
#
#   make serve                      # the committed demo pack
#   make serve PACK=mapdata/berlin  # a pack you built for yourself

PACK  ?= mapdata/active
PORT  ?= 8765

serve:
	cd $(PACK_DIR) && $(PYTHON) -m mappack.serve \
		--pack "$(CURDIR)/$(PACK)" \
		--index "$(if $(filter mapdata/active,$(PACK)),$(CURDIR)/source/generated/MapIndex.mc,$(CURDIR)/$(PACK)/MapIndex.mc)" \
		--port $(PORT)

# --- checks ----------------------------------------------------------------

test:
	cd $(PACK_DIR) && $(PYTHON) -m unittest discover -s tests -t . -v

lint:
	cd $(PACK_DIR) && $(PYTHON) -m compileall -q mappack tests

clean:
	rm -rf $(BIN)

distclean: clean
	rm -rf mapdata/active
