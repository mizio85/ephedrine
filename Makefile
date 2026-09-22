APP_NAME := Ephedrine
# Overridable from the environment/CI: `make dist VERSION=1.2.3`
VERSION ?= 1.0.0

.PHONY: build app run install clean dist

build:
	swift build

app:
	CONFIG=release ./scripts/build-app.sh

run: app
	open build/$(APP_NAME).app

install: app
	rm -rf /Applications/$(APP_NAME).app
	cp -R build/$(APP_NAME).app /Applications/
	open /Applications/$(APP_NAME).app

clean:
	swift package clean
	rm -rf build

# Universal (arm64 + x86_64) app bundle + zip ready to attach to a GitHub release.
dist:
	VERSION="$(VERSION)" ARCHS="arm64 x86_64" CONFIG=release ./scripts/build-app.sh
	ditto -c -k --keepParent build/$(APP_NAME).app build/$(APP_NAME)-$(VERSION).zip
	@echo "Distribuzione pronta: build/$(APP_NAME)-$(VERSION).zip"
