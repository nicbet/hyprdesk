# hyprdesk — common tasks. Run `make` or `make help` for the list.

CONFIG ?= debug
APP    := build/HyprDesk.app
BINDIR ?= $(HOME)/.local/bin

.DEFAULT_GOAL := help
.PHONY: help build release test app run dev stop snapshot readme-images icon install-cli signing-cert reset-permissions clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Compile (CONFIG=debug|release, default debug)
	swift build -c $(CONFIG)

release: ## Build a release HyprDesk.app
	scripts/bundle.sh release

test: ## Run all tests
	swift test

app: ## Build HyprDesk.app (CONFIG=debug|release)
	scripts/bundle.sh $(CONFIG)

run: app ## Build and launch HyprDesk.app
	@scripts/stop.sh
	open $(APP)

dev: ## Rebuild a debug bundle and relaunch it with Manage Workspaces open
	scripts/dev.sh

stop: ## Quit a running hyprdesk
	@scripts/stop.sh

snapshot: build ## Render the overview with sample spaces to build/snapshots/*.png
	$$(swift build -c $(CONFIG) --show-bin-path)/hyprdesk --snapshot build/snapshots

readme-images: build ## Render the README's picture (sample data) into docs/overview.jpg
	$$(swift build -c $(CONFIG) --show-bin-path)/hyprdesk --readme-images build/readme
	@mkdir -p docs
	@sips -s format jpeg -s formatOptions 88 build/readme/overview.png --out docs/overview.jpg >/dev/null
	@ls -lh docs

install-cli: app ## Link the `hyprdesk` command into BINDIR (default ~/.local/bin)
	@mkdir -p $(BINDIR)
	ln -sf "$(abspath $(APP))/Contents/MacOS/hyprdesk" "$(BINDIR)/hyprdesk"
	@echo "hyprdesk → $(BINDIR)/hyprdesk (make sure $(BINDIR) is on your PATH)"

icon: ## Redraw the app icon (scripts/make-icon.swift) into Resources/AppIcon.icns
	swift scripts/make-icon.swift

signing-cert: ## Create a local signing certificate so permissions survive rebuilds
	scripts/create-signing-cert.sh

reset-permissions: ## Reset HyprDesk's Accessibility grant
	tccutil reset Accessibility com.github.nicbet.hyprdesk

clean: ## Remove build output
	swift package clean
	rm -rf build
