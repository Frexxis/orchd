.PHONY: build-tui install-tui run-tui cross-tui test-go

build-tui:
	go build -o bin/orchd-tui ./cmd/orchd-tui

install-tui: build-tui
	mkdir -p $(HOME)/.local/bin
	cp -f bin/orchd-tui $(HOME)/.local/bin/orchd-tui

run-tui: build-tui
	./bin/orchd-tui

cross-tui:
	mkdir -p dist
	GOOS=linux GOARCH=amd64 go build -o dist/orchd-tui-linux-amd64 ./cmd/orchd-tui
	GOOS=darwin GOARCH=amd64 go build -o dist/orchd-tui-darwin-amd64 ./cmd/orchd-tui
	GOOS=darwin GOARCH=arm64 go build -o dist/orchd-tui-darwin-arm64 ./cmd/orchd-tui
	GOOS=windows GOARCH=amd64 go build -o dist/orchd-tui-windows-amd64.exe ./cmd/orchd-tui

test-go:
	go test ./...
