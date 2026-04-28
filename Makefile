.PHONY: test package-app

test:
	scripts/check-unit-coverage.sh

package-app:
	scripts/package-app.sh
