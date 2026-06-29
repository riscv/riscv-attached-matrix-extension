# Makefile for AME (Ztt) Specification PDF
#
# Self-contained build — no UDB, no submodules, no Docker required.
#
# Quick start (clean environment):
#   ./setup.sh       # install all dependencies (one-time)
#   make pdf         # build the PDF
#
# Or manually:
#   gem install asciidoctor asciidoctor-pdf asciidoctor-diagram asciidoctor-lists rouge
#   npm install -g wavedrom-cli
#   make pdf

EXTENSION := Ztt
VERSION := 0.3
OUTFILE := $(EXTENSION)-$(VERSION).pdf

BUILD_TIME := $(shell date -u '+%Y-%m-%d %H:%M:%S UTC')
BUILD_COMMIT := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)

SRC_DIR := src
BUILD_DIR := build
DOCS_RESOURCES := docs-resources

WAVEDROM := $(shell command -v wavedrom-cli 2>/dev/null)

ENV := LANG=C.utf8

ASCIIDOCTOR_PDF := $(ENV) asciidoctor-pdf

ALL_SRCS := $(wildcard $(SRC_DIR)/*.adoc)
ALL_IMAGES := $(wildcard $(SRC_DIR)/images/*)

OPTIONS := --trace \
	-r asciidoctor-diagram \
	-r asciidoctor-lists \
	-a build-time="$(BUILD_TIME)" \
	-a build-commit=$(BUILD_COMMIT) \
	-a pdf-fontsdir=$(abspath $(DOCS_RESOURCES)/fonts) \
	-a pdf-theme=$(abspath $(DOCS_RESOURCES)/themes/riscv-pdf.yml) \
	--failure-level=ERROR

ifneq ($(WAVEDROM),)
OPTIONS += -a wavedrom=$(WAVEDROM)
endif

.PHONY: default pdf clean build-tags

default: pdf

pdf: $(BUILD_DIR)/$(OUTFILE)

$(BUILD_DIR)/$(OUTFILE): $(SRC_DIR)/riscv-spec.adoc $(ALL_SRCS) $(ALL_IMAGES)
	@mkdir -p $(BUILD_DIR)
	$(ASCIIDOCTOR_PDF) \
		$(OPTIONS) \
		-a imagesdir=$(abspath $(SRC_DIR)/images) \
		-o $@ \
		$<
	@echo ""
	@echo "SUCCESS. Wrote PDF to $@"

build-tags:
	@echo "No normative tags for AME spec"

clean:
	rm -rf $(BUILD_DIR)
