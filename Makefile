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

.PHONY: build test app run clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	./scripts/make-app.sh

run:
	swift run PullMark

clean:
	rm -rf .build dist
