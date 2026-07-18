# When building with Command Line Tools (no Xcode), SwiftPM doesn't add the
# search paths for the bundled Swift Testing framework; full Xcode handles
# this automatically.
DEVDIR := $(shell xcode-select -p)
ifneq (,$(findstring CommandLineTools,$(DEVDIR)))
TESTING_DIR := $(DEVDIR)/Library/Developer
TEST_FLAGS := -Xswiftc -F$(TESTING_DIR)/Frameworks \
	-Xlinker -rpath -Xlinker $(TESTING_DIR)/Frameworks \
	-Xlinker -rpath -Xlinker $(TESTING_DIR)/usr/lib
endif

# Prefer the Homebrew bin (user-writable on Apple Silicon), else /usr/local.
BIN_DIR ?= $(shell [ -w /opt/homebrew/bin ] && echo /opt/homebrew/bin || echo /usr/local/bin)

.PHONY: build test app run clean install-cli release

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	./scripts/make-app.sh

run:
	swift run PullMark

install-cli:
	install -m 0755 bin/pullmark $(BIN_DIR)/pullmark
	@echo "Installed $(BIN_DIR)/pullmark"

clean:
	rm -rf .build dist

release:
	./scripts/make-release.sh $(VERSION)
