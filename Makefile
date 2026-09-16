SHELL := /bin/zsh
.PHONY: build run test install verify release
build:
	./scripts/build-app.sh
run:
	./scripts/build-and-launch.sh
test:
	./scripts/test.sh
install:
	./scripts/install-app.sh
verify:
	./scripts/verify-app.sh ./dist/ModRadio.app
release:
	./scripts/package-release.sh
