VERSION ?= dev
NAME    := mtouch-$(VERSION)-macos-arm64
BINDIR   = $(shell swift build -c release --arch arm64 --show-bin-path)

.PHONY: build test release package ungranted clean

build:
	swift build

test:
	swift test

## release: build an arm64 release binary (Apple Silicon)
release:
	swift build -c release --arch arm64
	@lipo -info "$(BINDIR)/mtouch"

## package: produce dist/$(NAME).tar.gz + .sha256 (make package VERSION=v0.1.0)
package: release
	@rm -rf dist/$(NAME) && mkdir -p dist/$(NAME)
	@cp "$(BINDIR)/mtouch" dist/$(NAME)/mtouch
	@cp README.md LICENSE dist/$(NAME)/
	@tar -C dist -czf "$(NAME).tar.gz" "$(NAME)"
	@shasum -a 256 "$(NAME).tar.gz" | tee "$(NAME).tar.gz.sha256"
	@echo "built $(NAME).tar.gz"

## ungranted: run the ungranted-persona live probes against the debug build
ungranted: build
	@chmod +x ci/ungranted-probes.sh
	@MTOUCH_BIN=.build/debug/mtouch ci/ungranted-probes.sh

clean:
	swift package clean
	rm -rf dist mtouch-*-macos-universal.tar.gz mtouch-*-macos-universal.tar.gz.sha256
