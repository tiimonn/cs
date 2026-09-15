# Thin shim for git-bash users. All logic lives in deploy.ps1 - these targets
# just call it with different flags. `pwsh -File deploy.ps1 ...` works fine
# on its own if you don't have `make` installed.
PWSH  ?= pwsh
FLAGS := -NoProfile -NonInteractive -File ./deploy.ps1

.DEFAULT_GOAL := help
.PHONY: help check diff deploy deploy-all dry-run accounts

help:        ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

check:       ## Lint + diff + launch-option report; never writes (exit 2 on drift)
	$(PWSH) $(FLAGS) -Check

diff:        ## Same as check, kept as an alias people expect
	$(PWSH) $(FLAGS) -Check

deploy:      ## Deploy autoexec.cfg
	$(PWSH) $(FLAGS)

deploy-all:  ## Deploy autoexec.cfg + cs2_video.txt (prompts for account if ambiguous)
	$(PWSH) $(FLAGS) -IncludeVideo

dry-run:     ## Full pipeline with -WhatIf, writes nothing
	$(PWSH) $(FLAGS) -WhatIf

accounts:    ## List local Steam accounts and their SteamID3
	$(PWSH) $(FLAGS) -ListAccounts
