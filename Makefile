.PHONY: help validate

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make validate  Run offline repository checks'

validate:
	@./scripts/validate.sh

