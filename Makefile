APP_NAME  := Name That Desktop
BUNDLE    := $(APP_NAME).app
BINARY    := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
SRC       := NameThatDesktop.swift

.PHONY: build install restart clean

build: namethatdesktop

namethatdesktop: $(SRC)
	swiftc -O -framework Cocoa $< -o $@

install: build
	@cp namethatdesktop "$(BINARY)"
	@echo "Installed into $(BUNDLE)"

restart: install
	@pid=$$(pgrep -f "$(BINARY)" 2>/dev/null) && kill $$pid \
		&& echo "Stopped old process ($$pid)" || true
	@open "$(BUNDLE)"
	@echo "Launched $(APP_NAME)"

clean:
	@rm -f namethatdesktop
