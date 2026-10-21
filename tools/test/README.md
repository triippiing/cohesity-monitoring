# Testing without a cluster

Everything here runs on Linux or Windows with PowerShell 7 (`pwsh`) and Python 3; the collector itself also runs on Windows PowerShell 5.1, which is what the scheduled task uses.

1. Start the mock Cohesity API, one made-up cluster per port (serves every endpoint the collector and reports read; accepts the `apiKey` header and the access-token login, pages the protection groups, and answers 405 to any method but GET and the login POST; `--expire` makes the first token expire once on each cluster):
   ```
   python3 tools/test/mock_api.py 18080 18081
   ```
2. Run the collector against it (`MOCK-A` uses AuthMode ApiKey on port 18080, `MOCK-B` AuthMode Password on 18081; the mock credential is user `mon`, password `pw`, which is also the API key, stored with Export-Clixml on Linux, so it is not DPAPI-protected and only works with the mock):
   ```
   pwsh -NoProfile -File ./Export-CohesityMetrics.ps1 -ConfigPath tools/test/mock.config.json -All -NonInteractive -TextfileDirectory tools/test/out
   promtool check metrics < tools/test/out/cohesity.prom
   ```
   Expect "Wrote ... samples for 2 cluster(s)" and every `cohesity_check_success` at 1. The second run counts one more new alert per cluster (the mock raises one every two minutes).
3. Validate the dashboards: serve the output file as `/metrics`, point a Prometheus at it, then run the validator. The test config needs Prometheus 3.0 or later: `python3 -m http.server` sends the extensionless file as `application/octet-stream`, which Prometheus 3 only accepts with the `fallback_scrape_protocol` line in `tools/test/prometheus-test.yml`, and 2.x rejects that field.
   ```
   ln -sf cohesity.prom tools/test/out/metrics
   (cd tools/test/out && python3 -m http.server 19100 --bind 127.0.0.1 &)
   prometheus --config.file=tools/test/prometheus-test.yml --storage.tsdb.path=tools/test/out/tsdb --web.listen-address=127.0.0.1:19090 &
   sleep 10; python3 tools/test/validate_dashboards.py
   ```
   Expect `errors 0`. A few `empty` lines are normal: `increase()` queries need more than one scrape and the 30-day trend needs history.

4. Render the dashboards in Grafana (optional; CI does it with Grafana 12.0.2 and the Business Text plugin). Publish them in the test theme, which also exercises every colour swap, the brand line and the logo, then provision `tools/test/out/dash` into a Grafana with anonymous access, the plugin in its `data/plugins` and a `Cohesity Prometheus` data source (uid `cohesity-prometheus`) pointing at `http://127.0.0.1:19090` (see the kit job in `.github/workflows/ci.yml`), and screenshot it with Python Playwright:
   ```
   pwsh -NoProfile -File ./Publish-CohesityDashboards.ps1 -ThemePath tools/test/theme-test.json -OutDirectory tools/test/out/dash -HtmlPanels
   python3 tools/test/render_dashboards.py --cards   # --chromium PATH to use an installed Chromium
   ```
   Expect the five screenshots in `tools/test/out/screens` and no `PROBLEM` line. Without the plugin, publish without `-HtmlPanels` and leave out `--cards`. The README screenshots in `docs/images` are `--full --from now-15m` renders (Grafana's menu and the whole page, anonymous Viewer) of the default theme, from a collector run every 20 seconds against the mock on four ports (`mock_api.py 18080 18081 18082 18083`, a config with the template names `COHESITY-01` to `COHESITY-04` and `-MaxParallel 1`) and about 15 minutes of history.

After changing a dashboard in `tools/build-dashboards.py`, regenerate with `python3 tools/build-dashboards.py` and re-run step 3. `python3 tools/build-package.py` builds the release zip into `dist/`.
