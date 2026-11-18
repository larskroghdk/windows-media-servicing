PWSH := pwsh -NoProfile -NonInteractive -File scripts/Invoke-QualityGate.ps1

.PHONY: check lint typecheck test

check: lint typecheck test

lint:
	$(PWSH) -Task Lint

typecheck:
	$(PWSH) -Task Typecheck

test:
	$(PWSH) -Task Test
