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
SDK_BIN     ?=
MONKEYC     := $(if $(SDK_BIN),$(SDK_BIN)/monkeyc,monkeyc)
MONKEYDO    := $(if $(SDK_BIN),$(SDK_BIN)/monkeydo,monkeydo)
SIMULATOR   := $(if $(SDK_BIN),$(SDK_BIN)/connectiq,connectiq)

KEY         ?= developer_key
BIN         := bin
PRG         := $(BIN)/offline-maps-$(DEVICE).prg
IQ          := $(BIN)/offline-maps.iq

PYTHON      ?= python3
PACKER      := $(PYTHON) -m mappack
PACK_DIR    := tools/mappack

# --- map pack inputs -------------------------------------------------------
# Either BBOX (fetched from Overpass) or INPUT (a local .osm / .osm.pbf file).
BBOX        ?=
INPUT       ?=
NAME        ?= $(if $(BBOX),custom,demo)
ZOOMS       ?= 12,14,16
SIMPLIFY    ?= 1.0
EXTRA       ?=

.PHONY: help key pack demo build sim package test lint clean distclean

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)
	@echo ""
	@echo "Targets:"
	@echo "  make key         generate a developer signing key (once)"
	@echo "  make pack        build a map pack   (BBOX=w,s,e,n  or  INPUT=file.osm)"
	@echo "  make demo        rebuild the bundled synthetic demo pack"
	@echo "  make build       compile for DEVICE=$(DEVICE)"
	@echo "  make sim         launch the simulator and side-load the app"
	@echo "  make package     build the .iq bundle for the Connect IQ store"
	@echo "  make test        run the packer test suite"
	@echo "  make clean       remove build output"

# --- signing ---------------------------------------------------------------

$(KEY):
	@echo ">> generating $(KEY) (keep it; the store ties your app id to it)"
	openssl genrsa -out $(KEY).pem 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER -in $(KEY).pem -out $(KEY) -nocrypt
	@rm -f $(KEY).pem

key: $(KEY)

# --- map data --------------------------------------------------------------

pack:
ifeq ($(strip $(BBOX)$(INPUT)),)
	$(error set BBOX=west,south,east,north or INPUT=path/to/region.osm)
endif
	cd $(PACK_DIR) && $(PACKER) \
		$(if $(INPUT),--input "$(abspath $(INPUT))") \
		$(if $(BBOX),--bbox "$(BBOX)") \
		--name "$(NAME)" --zooms "$(ZOOMS)" --simplify $(SIMPLIFY) \
		--out "$(CURDIR)/mapdata/active" \
		--index "$(CURDIR)/source/generated/MapIndex.mc" \
		$(EXTRA)

demo:
	cd $(PACK_DIR) && $(PACKER) --input tests/demo-city.osm --name "Demo City" \
		--zooms 12,14,16 \
		--out "$(CURDIR)/mapdata/active" \
		--index "$(CURDIR)/source/generated/MapIndex.mc"

# --- build -----------------------------------------------------------------

build: $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -f monkey.jungle -o $(PRG) -y $(KEY) -d $(DEVICE) -w
	@ls -lh $(PRG)

sim: build
	@echo ">> starting simulator (leave it running), then side-loading"
	@($(SIMULATOR) &) ; sleep 6 ; $(MONKEYDO) $(PRG) $(DEVICE)

package: $(KEY)
	@mkdir -p $(BIN)
	$(MONKEYC) -e -f monkey.jungle -o $(IQ) -y $(KEY) -w -r
	@ls -lh $(IQ)

# --- checks ----------------------------------------------------------------

test:
	cd $(PACK_DIR) && $(PYTHON) -m unittest discover -s tests -t . -v

lint:
	cd $(PACK_DIR) && $(PYTHON) -m compileall -q mappack tests

clean:
	rm -rf $(BIN)

distclean: clean
	rm -rf mapdata/active
