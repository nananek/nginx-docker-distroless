IMAGE ?= nginx-distroless:dev

.PHONY: image test check

image:
	docker build --platform linux/amd64 -t "$(IMAGE)" .

test: image
	./scripts/smoke-test.sh "$(IMAGE)"

check:
	for script in scripts/*.sh; do bash -n "$$script"; done
