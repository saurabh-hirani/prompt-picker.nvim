.PHONY: release

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=v0.0.4 NOTES='notes' or NOTES_FILE=notes.txt"; exit 1; fi
	@if [ -n "$(NOTES_FILE)" ]; then \
		git tag -a $(VERSION) -F $(NOTES_FILE); \
	elif [ -n "$(NOTES)" ]; then \
		git tag -a $(VERSION) -m "$(VERSION) - $(NOTES)"; \
	else \
		echo "Provide either NOTES='...' or NOTES_FILE=file.txt"; exit 1; \
	fi
	git push origin $(VERSION)
	@echo "Released $(VERSION)"
