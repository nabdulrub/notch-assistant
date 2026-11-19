# The Mac app lives in apps/mac and the landing page in apps/web.
# `make run`, `make test`, `make dist` and the rest are passed on to the app.
.PHONY: web

web:
	@cd apps/web && python3 -m http.server 4321

%:
	@$(MAKE) -C apps/mac $@
