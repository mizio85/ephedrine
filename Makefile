APP_NAME := Ephedrine

.PHONY: build app run install clean

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
