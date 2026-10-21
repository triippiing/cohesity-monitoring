#!/usr/bin/env python3
"""Generates the Grafana dashboards in monitoring/dashboards/:
Fleet, Activity, Instance, Patch management, Alerts, and in monitoring/dashboards-html/ the variants that use the
Business Text panel plugin (Fleet's estate cards). Re-run after changing metrics or layout.
Colours come from monitoring/theme.example.json. Native panels use Grafana's named colours (green, orange, red,
blue) and the HTML uses the example theme's hex values; Publish-CohesityDashboards.ps1 swaps both for a site's
theme.json, so every hex value in the example theme must be unique."""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION = open(os.path.join(ROOT, 'VERSION')).read().strip()
OUT_DIR = os.path.join(ROOT, 'monitoring', 'dashboards')
HTML_DIR = os.path.join(ROOT, 'monitoring', 'dashboards-html')
LEVEL = {"green": "ok", "orange": "warning", "red": "critical", "blue": "info"}
THEME = json.load(open(os.path.join(ROOT, 'monitoring', 'theme.example.json')))
C = THEME["colors"]
assert len({v.upper() for v in C.values()}) == len(C), "theme.example.json colours must be unique"
BT_PANEL = "marcusolsson-dynamictext-panel"
DS = {"type": "prometheus", "uid": "${datasource}"}
REFS = "ABCDEFGHIJKLMNOP"
INSTANCE_URL = "/d/cohesity-instance/cohesity-instance?var-cluster=${__data.fields.cluster}"
OKFAIL = [{"type": "value", "options": {"1": {"text": "OK", "color": "green"}, "0": {"text": "FAIL", "color": "red"}}}]
YESNO = [{"type": "value", "options": {"1": {"text": "Yes", "color": "red"}, "0": {"text": "No", "color": "green"}}}]
GREEN_RED = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
RED_GREEN = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
BLUE = [{"color": "blue", "value": None}]
STATE_COLORS = [
    {"type": "regex", "options": {"pattern": ".*(error|fail|stopped|missed|canceled|cancelled|unregister|infected|critical).*", "result": {"color": "red"}}},
    {"type": "regex", "options": {"pattern": ".*(running|accepted|onhold|paused|finalizing|canceling|warning|pending|scheduled|refresh|quarantin).*", "result": {"color": "orange"}}},
    {"type": "regex", "options": {"pattern": "^(succeeded|registered|finished|none|dontremove|ok|healthy)$", "result": {"color": "green"}}},
]


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


class Dashboard:
    def __init__(self, title, uid, cluster_filter, cluster_var, time_from="now-24h", refresh="1m", description="", html=False):
        """html: the Business Text variant, where a section whose stat panels follow its header is drawn as one panel
        (section(): header, navy ground, rounded tiles) instead of a header and a row of stat panels."""
        self.title, self.uid, self.S, self.cluster_var = title, uid, cluster_filter, cluster_var
        self.time_from, self.refresh, self.description, self.html = time_from, refresh, description, html
        self.panels, self._id, self._y, self._x, self._h = [], 0, 0, 0, 0
        self._section = None
        self.banner()

    def nid(self):
        self._id += 1
        return self._id

    def place(self, w, h):
        self.flush()
        if self._x + w > 24:
            self._y += self._h
            self._x, self._h = 0, 0
        pos = {"h": h, "w": w, "x": self._x, "y": self._y}
        self._x += w
        self._h = max(self._h, h)
        return pos

    def row(self, title):
        """Section header: a rounded pill in a core text panel, in place of a Grafana row (whose header cannot be
        styled), so every section heading matches the banner and the cards. Sections are always open. In the html
        variant the header waits: stat panels that follow it become the tiles of one section() panel."""
        self.flush()
        if self.html:
            self._section = {"title": title, "tiles": []}
            return
        self.header(title)

    def flush(self):
        """Writes a waiting html section: section() when stat panels followed its header, else the plain header."""
        sec, self._section = self._section, None
        if sec and sec["tiles"]:
            self.section(sec["title"], sec["tiles"])
        elif sec:
            self.header(sec["title"])

    def header(self, title):
        self._y += self._h
        self._x, self._h = 0, 0
        # Two grid units (one leaves the text panel too little room inside its padding); the pill spans the dashboard
        # and sits at the bottom, next to the panels it heads.
        html = ('<div style="display:flex;align-items:flex-end;width:100%%;height:100%%"><div style="display:flex;align-items:center;gap:10px;'
                'width:100%%;box-sizing:border-box;height:36px;padding:0 18px;border-radius:999px;'
                'background:linear-gradient(90deg,%(surface)s 0%%,%(background)s 100%%);border:1px solid %(surface)s">'
                '<span style="color:%(label)s;font-size:12px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;'
                'white-space:nowrap;overflow:hidden;text-overflow:ellipsis">%(title)s</span></div></div>') % dict(C, title=esc(title))
        self.panels.append({"type": "text", "title": "", "id": self.nid(), "gridPos": self.place(24, 2), "transparent": True,
                            "options": {"mode": "html", "content": html}})
        self._y += self._h
        self._x, self._h = 0, 0

    def target(self, expr, ref, legend=None, table=False):
        t = {"datasource": DS, "refId": ref, "expr": expr}
        if legend:
            t["legendFormat"] = legend
        if table:
            t.update({"format": "table", "instant": True})
        return t

    def banner(self):
        """Header strip above the first section: logo, brand line and package version, 48 px high to fit the 50 px a
        two-unit text panel has inside its padding. Plain HTML in a core text panel; Publish-CohesityDashboards.ps1
        puts the theme's logo and brand at the <!--logo--> and <!--brand--> markers and the installed VERSION at
        <!--version-->."""
        html = ('<div style="display:flex;align-items:center;gap:18px;height:48px;box-sizing:border-box;padding:0 18px;border-radius:6px;'
                'background:linear-gradient(90deg,%(background)s 0%%,%(surface)s 100%%);border-left:4px solid %(accent)s">'
                '<!--logo--><div style="min-width:0;color:%(label)s;font-size:15px;font-weight:700;letter-spacing:1.5px;'
                'text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'
                '<!--brand-->%(brand)s<!--/brand--> &middot; <!--version-->v%(version)s<!--/version--></div></div>'
                ) % dict(C, brand=esc(THEME["brand"]), version=esc(VERSION))
        self.panels.append({"type": "text", "title": "", "id": self.nid(), "gridPos": self.place(24, 2), "transparent": True,
                            "options": {"mode": "html", "content": html}})

    def text(self, title, content, w=24, h=3):
        self.panels.append({"type": "text", "title": title, "id": self.nid(), "gridPos": self.place(w, h),
                            "options": {"mode": "markdown", "content": content}})

    def ts(self, title, exprs, unit=None, w=12, h=8, stack=False, bars=False, desc=None, legend_right=True, min0=True):
        defaults = {"custom": {"fillOpacity": 80 if bars else 15, "lineWidth": 1, "showPoints": "never"}}
        if stack:
            defaults["custom"]["stacking"] = {"mode": "normal"}
        if bars:
            defaults["custom"]["drawStyle"] = "bars"
        if unit:
            defaults["unit"] = unit
        if min0:
            defaults["min"] = 0
        legend = {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull"]} if legend_right else {"displayMode": "list", "placement": "bottom"}
        p = {"type": "timeseries", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], l) for i, (e, l) in enumerate(exprs)],
             "fieldConfig": {"defaults": defaults, "overrides": []}, "options": {"legend": legend, "tooltip": {"mode": "multi", "sort": "desc"}}}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def stat(self, title, exprs, unit=None, w=4, h=4, mappings=None, thresholds=None, desc=None, decimals=None, links=None, sparkline=False, text_mode=None):
        if self._section is not None:
            self._section["tiles"].append({"title": title, "exprs": exprs, "unit": unit, "mappings": mappings,
                                           "thresholds": thresholds or BLUE, "decimals": decimals, "desc": desc})
            return
        defaults = {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": thresholds or BLUE}}
        if unit:
            defaults["unit"] = unit
        if mappings:
            defaults["mappings"] = mappings
        if decimals is not None:
            defaults["decimals"] = decimals
        if links:
            defaults["links"] = links
        p = {"type": "stat", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], l) for i, (e, l) in enumerate(exprs)],
             "fieldConfig": {"defaults": defaults, "overrides": []},
             "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                         "colorMode": "background", "graphMode": "area" if sparkline else "none",
                         "textMode": text_mode or ("value_and_name" if len(exprs) > 1 or "{{" in (exprs[0][1] or "") else "value"), "wideLayout": True}}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def cards(self, cards, title, w=24, h=9, desc=None):
        """A whole section in a Business Text panel: the section header, and under it on a navy ground a health
        summary and one rounded tile per card (in place of row() and a row of stat panels). cards: list of
        (key, label, expr, unit, warn, crit); warn/crit are the lowest values that colour a tile (None for never;
        both None makes an informational tile). One instant query returns every value, labelled k=<key>."""
        self.flush()
        self._y += self._h
        self._x, self._h = 0, 0
        expr = " or ".join('label_replace(%s, "k", "%s", "", "")' % (e, k) for k, _, e, _, _, _ in cards)
        spec = [{"k": k, "label": label, "unit": unit, "warn": warn, "crit": crit} for k, label, _, unit, warn, crit in cards]
        p = {"type": BT_PANEL, "title": "", "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h), "transparent": True,
             "targets": [self.target(expr, "A", table=True)],
             "options": {"renderMode": "allRows", "content": "{{{cohesityCards data}}}", "defaultContent": CARDS_EMPTY % esc(title),
                         "helpers": CARDS_JS.replace("__CARDS__", json.dumps(spec)).replace("__TITLE__", json.dumps(title)), "styles": CARDS_CSS % C, "wrap": False,
                         "editors": ["helpers", "styles"], "editor": {"format": "auto", "language": "html"},
                         "contentPartials": [], "externalStyles": [], "afterRender": "", "status": ""}}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def section(self, title, tiles, h=6):
        """One Business Text panel for a section of stat tiles: the header pill and, on a navy ground under it, one
        rounded tile per stat with the stat's thresholds, value mappings, unit and legend. One instant query returns
        every tile's series, labelled k=<tile number>."""
        self._y += self._h
        self._x, self._h = 0, 0
        expr = " or ".join('label_replace(%s, "k", "%d", "", "")' % (e, i) for i, t in enumerate(tiles) for e, _ in t["exprs"])
        spec = []
        for i, t in enumerate(tiles):
            maps = {}
            for m in t["mappings"] or []:
                for value, r in m["options"].items():
                    maps[value] = {"text": r["text"], "level": LEVEL[r["color"]]}
            spec.append({"k": str(i), "label": t["title"], "unit": t["unit"], "decimals": t["decimals"], "legend": t["exprs"][0][1],
                         "list": t["exprs"][0][0].startswith("count by"),
                         "maps": maps, "steps": [[st["value"], LEVEL[st["color"]]] for st in t["thresholds"]]})
        desc = " ".join("%s: %s" % (t["title"], t["desc"]) for t in tiles if t["desc"])
        p = {"type": BT_PANEL, "title": "", "id": self.nid(), "datasource": DS, "gridPos": self.place(24, h), "transparent": True,
             "targets": [self.target(expr, "A", table=True)],
             "options": {"renderMode": "allRows", "content": "{{{cohesitySection data}}}", "defaultContent": SECTION_EMPTY % esc(title),
                         "helpers": SECTION_JS.replace("__SECTION__", json.dumps({"title": title, "tiles": spec})),
                         "styles": (CARDS_CSS + SECTION_CSS) % C, "wrap": False,
                         "editors": ["helpers", "styles"], "editor": {"format": "auto", "language": "html"},
                         "contentPartials": [], "externalStyles": [], "afterRender": "", "status": ""}}
        if desc:
            p["description"] = desc
        self.panels.append(p)
        self._y += self._h
        self._x, self._h = 0, 0

    def table(self, title, exprs, rename=None, units=None, hide=None, w=24, h=8, sort=None, desc=None, merge=True,
              order=None, color_cols=None, links=None, bool_cols=None, bar_cols=None, filterable=False, hide_time=True):
        """exprs: list of PromQL (table format, instant). Value columns are 'Value #<ref>' (or 'Value' for one query);
        rename maps ref -> column name (None drops the column). order lists column names first-to-last."""
        exclude = {"__name__": True, "instance": True, "job": True}
        if hide_time:
            exclude["Time"] = True
        for x in (hide or []):
            exclude[x] = True
        ren = {}
        for ref, name in (rename or {}).items():
            col = "Value #%s" % ref if len(exprs) > 1 else "Value"
            if name is None:
                exclude[col] = True
            else:
                ren[col] = name
        overrides = []
        for name, unit in (units or {}).items():
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [{"id": "unit", "value": unit}]})
        for name in (color_cols or []):
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "mappings", "value": STATE_COLORS}]})
        for name in (bool_cols or []):
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "color-text"}}, {"id": "mappings", "value": OKFAIL}]})
        for name, (lo, hi) in (bar_cols or {}).items():
            # A progress bar is never a warning; a usage bar turns orange at 80 and red at 90.
            steps = [{"color": "blue", "value": None}] if name.startswith("Progress") else \
                [{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]
            overrides.append({"matcher": {"id": "byName", "options": name}, "properties": [
                {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}, {"id": "min", "value": lo}, {"id": "max", "value": hi},
                {"id": "thresholds", "value": {"mode": "absolute", "steps": steps}}]})
        if links:
            overrides.append({"matcher": {"id": "byName", "options": "cluster"}, "properties": [{"id": "links", "value": links}]})
        tr = []
        if merge and len(exprs) > 1:
            # Merge joins rows only when every shared column matches. Raw series carry __name__ (which differs per
            # query) and Time, so drop both first or the rows from each query land one under the other.
            tr.append({"id": "filterFieldsByName", "options": {"exclude": {"pattern": "^(__name__|Time)$"}}})
            tr.append({"id": "merge", "options": {}})
        org = {"excludeByName": exclude, "renameByName": ren}
        if order:
            # Organize positions fields by their names before the rename, so map renamed columns back.
            original = {v: k for k, v in ren.items()}
            org["indexByName"] = {original.get(name, name): i for i, name in enumerate(order)}
        tr.append({"id": "organize", "options": org})
        if sort:
            tr.append({"id": "sortBy", "options": {"sort": [{"field": sort[0], "desc": sort[1]}]}})
        p = {"type": "table", "title": title, "id": self.nid(), "datasource": DS, "gridPos": self.place(w, h),
             "targets": [self.target(e, REFS[i], table=True) for i, e in enumerate(exprs)],
             "fieldConfig": {"defaults": {"custom": {"filterable": filterable}}, "overrides": overrides},
             "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}}, "transformations": tr}
        if desc:
            p["description"] = desc
        self.panels.append(p)

    def build(self):
        self.flush()
        variables = [{"name": "datasource", "type": "datasource", "query": "prometheus", "label": "Data source",
                      "current": {"text": "Cohesity Prometheus", "value": "cohesity-prometheus"}}]
        if self.cluster_var == "multi":
            variables.append({"name": "cluster", "type": "query", "datasource": DS, "query": {"query": "label_values(cohesity_up, cluster)", "refId": "A"},
                              "definition": "label_values(cohesity_up, cluster)", "includeAll": True, "multi": True, "sort": 1,
                              "current": {"text": "All", "value": "$__all"}, "refresh": 2, "label": "Cluster"})
        elif self.cluster_var == "single":
            variables.append({"name": "cluster", "type": "query", "datasource": DS, "query": {"query": "label_values(cohesity_up, cluster)", "refId": "A"},
                              "definition": "label_values(cohesity_up, cluster)", "includeAll": False, "multi": False, "sort": 1,
                              "refresh": 2, "label": "Cluster"})
        return {
            "title": self.title, "uid": self.uid, "schemaVersion": 39, "version": 1, "editable": True, "graphTooltip": 1,
            "refresh": self.refresh, "time": {"from": self.time_from, "to": "now"}, "tags": ["cohesity"], "description": self.description,
            "links": [{"title": "Cohesity dashboards", "type": "dashboards", "tags": ["cohesity"], "asDropdown": False, "includeVars": True, "keepTime": True}],
            "templating": {"list": variables}, "panels": self.panels,
        }


# Business Text helper code for Dashboard.cards. Runs in the browser; the template is {{{cohesityCards data}}}
# (the rows of the panel's one query, each with the k label and the value). Everything printed is escaped.
CARDS_JS = r"""const CARDS = __CARDS__;
const TITLE = __TITLE__;
const num = (row) => {
  for (const key of Object.keys(row)) {
    if (key.indexOf('Value') === 0) { return Number(row[key]); }
  }
  return NaN;
};
const esc = (s) => String(s).replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[ch]);
const fmt = (v, unit) => {
  if (!isFinite(v)) { return '-'; }
  if (unit === 's') {
    if (v < 90) { return Math.round(v) + ' s'; }
    if (v < 5400) { return (v / 60).toFixed(1) + ' min'; }
    return (v / 3600).toFixed(1) + ' h';
  }
  return String(Math.round(v));
};
const level = (v, c) => {
  if (!isFinite(v)) { return 'unknown'; }
  if (c.crit !== null && v >= c.crit) { return 'critical'; }
  if (c.warn !== null && v >= c.warn) { return 'warning'; }
  return c.crit === null && c.warn === null ? 'info' : 'ok';
};
const WORD = { ok: 'OK', warning: 'Check', critical: 'Action', info: 'Info', unknown: 'No data' };
context.handlebars.registerHelper('cohesityCards', (rows) => {
  const values = {};
  (rows || []).forEach((row) => { values[row.k] = num(row); });
  let attention = 0;
  let worst = 'ok';
  const tiles = CARDS.map((c) => {
    const v = values[c.k];
    const lv = level(v, c);
    if (lv === 'critical' || lv === 'warning' || lv === 'unknown') { attention += 1; }
    if (lv === 'critical' || (lv !== 'ok' && lv !== 'info' && worst === 'ok')) { worst = lv; }
    return '<div class="ss-card ' + lv + '"><div class="ss-label" title="' + esc(c.label) + '">' + esc(c.label) + '</div>' +
      '<div class="ss-value">' + esc(fmt(v, c.unit)) + '</div><div class="ss-pill">' + WORD[lv] + '</div></div>';
  }).join('');
  const total = values.clusters;
  const down = values.api_down;
  const reach = isFinite(total) && isFinite(down) ? (total - down) + ' of ' + total + ' clusters reachable' : 'Cluster count not available';
  const title = attention === 0 ? 'All clusters healthy' : attention + (attention === 1 ? ' indicator needs' : ' indicators need') + ' attention';
  const mark = attention === 0 ? '&#10003;' : '!';
  const hero = '<div class="ss-hero ' + (attention === 0 ? 'ok' : worst) + '"><div class="ss-mark">' + mark + '</div>' +
    '<div class="ss-hero-title">' + esc(title) + '</div><div class="ss-hero-sub">' + esc(reach) + '</div></div>';
  return new context.handlebars.SafeString('<div class="ss-section"><div class="ss-head">' + esc(TITLE) + '</div>' +
    '<div class="ss">' + hero + tiles + '</div></div>');
});
"""
CARDS_EMPTY = '<div class="ss-section"><div class="ss-head">%s</div><div class="ss"><div class="ss-hero unknown"><div class="ss-mark">?</div><div class="ss-hero-title">No data</div><div class="ss-hero-sub">Prometheus returned nothing for the estate cards.</div></div></div></div>'
CARDS_CSS = """.ss-section { display: flex; flex-direction: column; height: 100%%; box-sizing: border-box; border-radius: 18px; overflow: hidden;
  background: %(background)s; border: 1px solid %(surface)s; }
.ss-head { flex: none; display: flex; align-items: center; gap: 10px; height: 36px; padding: 0 18px; border-radius: 18px;
  background: linear-gradient(90deg, %(surface)s 0%%, %(background)s 100%%); color: %(label)s; font-size: 12px; font-weight: 700; letter-spacing: 1.5px; text-transform: uppercase; }
.ss { flex: 1; min-height: 0; display: grid; grid-template-columns: minmax(240px, 1.4fr) repeat(4, minmax(140px, 1fr)); grid-auto-rows: 1fr; gap: 10px; padding: 10px 12px 12px; }
.ss-hero { grid-row: span 2; display: flex; flex-direction: column; justify-content: center; gap: 6px; padding: 16px 20px; border-radius: 14px;
  background: linear-gradient(135deg, %(background)s 0%%, %(surface)s 100%%); border-left: 4px solid %(accent)s; }
.ss-mark { width: 44px; height: 44px; border-radius: 50%%; border: 3px solid currentColor; display: flex; align-items: center; justify-content: center; font-size: 22px; font-weight: 700; }
.ss-hero-title { font-size: 22px; font-weight: 700; line-height: 1.2; }
.ss-hero-sub { color: %(muted)s; font-size: 13px; }
.ss-card { display: flex; flex-direction: column; justify-content: space-between; gap: 4px; min-width: 0; padding: 10px 14px; border-radius: 14px;
  background: %(surface)s; border-top: 3px solid %(info)s; }
.ss-label { color: %(label)s; font-size: 11px; font-weight: 700; letter-spacing: 1.2px; text-transform: uppercase; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ss-value { color: #FFFFFF; font-size: 32px; font-weight: 700; line-height: 1.1; }
.ss-pill { align-self: flex-start; padding: 2px 9px; border-radius: 10px; color: #FFFFFF; font-size: 11px; font-weight: 700; letter-spacing: 0.6px; text-transform: uppercase; }
.ss-hero.ok { color: %(ok)s; } .ss-hero.warning { color: %(warning)s; } .ss-hero.critical { color: %(critical)s; } .ss-hero.unknown { color: %(muted)s; }
.ss-hero .ss-hero-title { color: #FFFFFF; }
.ss-card.ok { border-top-color: %(ok)s; } .ss-card.ok .ss-pill { background: %(ok)s; }
.ss-card.info .ss-pill { background: %(info)s; }
.ss-card.warning { border-top-color: %(warning)s; background: linear-gradient(180deg, %(warning)s40 0%%, %(surface)s 70%%); } .ss-card.warning .ss-pill { background: %(warning)s; }
.ss-card.critical { border-top-color: %(critical)s; background: linear-gradient(180deg, %(critical)s40 0%%, %(surface)s 70%%); } .ss-card.critical .ss-pill { background: %(critical)s; }
.ss-card.unknown { border-top-color: %(muted)s; } .ss-card.unknown .ss-pill { background: %(muted)s; color: %(background)s; }
"""

# Business Text helper code for Dashboard.section. Runs in the browser; the template is {{{cohesitySection data}}}
# (the rows of the panel's one query, each with the k label, the series' other labels and the value). Mirrors what
# the stat panels show: value mappings first, else the legend (label text) or the value in the stat's unit, coloured
# by the stat's thresholds. Everything printed is escaped.
SECTION_JS = r"""const SECTION = __SECTION__;
const num = (row) => {
  for (const key of Object.keys(row)) {
    if (key.indexOf('Value') === 0) { return Number(row[key]); }
  }
  return NaN;
};
const esc = (s) => String(s).replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[ch]);
const round = (v, d, auto) => v.toFixed(d !== null ? d : (Math.abs(v) >= auto || Number.isInteger(v) ? 0 : 1));
const pad = (n) => String(n).padStart(2, '0');
const fmt = (v, t) => {
  if (!isFinite(v)) { return 'No data'; }
  switch (t.unit) {
    case 'percent': return round(v, t.decimals, 100) + '%';
    case 'bytes': {
      const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
      let i = 0;
      while (Math.abs(v) >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
      return round(v, t.decimals, 100) + ' ' + units[i];
    }
    case 's': {
      const a = Math.abs(v);
      if (a < 90) { return round(v, t.decimals, 10) + ' s'; }
      if (a < 5400) { return (v / 60).toFixed(1) + ' min'; }
      if (a < 172800) { return (v / 3600).toFixed(1) + ' h'; }
      return (v / 86400).toFixed(1) + ' days';
    }
    case 'd': return round(v, t.decimals, 10) + ' days';
    case 'dateTimeAsIso': {
      const d = new Date(v);
      return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
    }
    default: return round(v, t.decimals, 100);
  }
};
const level = (v, t) => {
  if (!isFinite(v)) { return 'unknown'; }
  let lv = 'info';
  t.steps.forEach((st) => { if (st[0] === null || v >= st[0]) { lv = st[1]; } });
  return lv;
};
const show = (row, t) => {
  const v = num(row);
  const m = t.maps[String(v)];
  if (m) { return { text: m.text, level: m.level }; }
  const text = t.legend ? t.legend.replace(/\{\{\s*(\w+)\s*\}\}/g, (all, name) => (row[name] === undefined ? '' : row[name])).trim() : fmt(v, t);
  return { text: text, level: level(v, t) };
};
const WORD = { ok: 'OK', warning: 'Check', critical: 'Action', info: 'Info', unknown: 'No data' };
context.handlebars.registerHelper('cohesitySection', (rows) => {
  const tiles = SECTION.tiles.map((t) => {
    const mine = (rows || []).filter((row) => row.k === t.k);
    let body;
    let lv = 'unknown';
    if (mine.length > 1 || (t.list && mine.length)) {
      // A count per version and the like: one line per series with its count, the tile coloured by the first.
      lv = show(mine[0], t).level;
      body = '<div class="ss-list">' + mine.map((row) => '<div><span>' + esc(show(row, t).text) + '</span><b>' + esc(fmt(num(row), Object.assign({}, t, { unit: null }))) + '</b></div>').join('') + '</div>';
    } else {
      const r = mine.length ? show(mine[0], t) : { text: 'No data', level: 'unknown' };
      lv = r.level;
      body = '<div class="ss-value' + (r.text.length > 10 ? ' ss-long' : '') + '" title="' + esc(r.text) + '">' + esc(r.text) + '</div>';
    }
    return '<div class="ss-card ' + lv + '"><div class="ss-label" title="' + esc(t.label) + '">' + esc(t.label) + '</div>' + body +
      '<div class="ss-pill">' + WORD[lv] + '</div></div>';
  }).join('');
  return new context.handlebars.SafeString('<div class="ss-section"><div class="ss-head">' + esc(SECTION.title) + '</div>' +
    '<div class="ss ss-tiles" style="grid-template-columns: repeat(' + SECTION.tiles.length + ', minmax(0, 1fr))">' + tiles + '</div></div>');
});
"""
SECTION_EMPTY = '<div class="ss-section"><div class="ss-head">%s</div><div class="ss ss-tiles"><div class="ss-hero unknown"><div class="ss-hero-title">No data</div><div class="ss-hero-sub">Prometheus returned nothing for this section.</div></div></div></div>'
SECTION_CSS = """.ss.ss-tiles { grid-auto-rows: auto; grid-template-rows: 1fr; }
.ss-tiles .ss-hero { grid-row: auto; grid-column: 1 / -1; }
.ss-value { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ss-value.ss-long { font-size: 20px; line-height: 1.2; white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.ss-list { display: flex; flex-direction: column; gap: 2px; font-size: 16px; font-weight: 600; color: #FFFFFF; overflow: hidden; }
.ss-list div { display: flex; justify-content: space-between; gap: 8px; } .ss-list span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
"""


def write(d, out_dir=OUT_DIR):
    path = os.path.join(out_dir, d.uid + ".json")
    with open(path, 'w') as f:
        json.dump(d.build(), f, indent=2)
    print("%-28s %3d panels  %s" % (d.title, sum(1 for p in d.panels if p['type'] != 'row'), path))


# ============================================================================ Fleet
def fleet(html=False):
    S = 'cluster=~"$cluster"'
    d = Dashboard("Cohesity Fleet", "cohesity-fleet", S, "multi", description="One row per cluster; red rows need attention. Click a cluster name to open its Instance page.", html=html)
    # (key, title, expr, unit, warn from, crit from): the stat row, or with html the Business Text section.
    estate = [
        ("clusters", "Clusters", f'count(cohesity_up{{{S}}})', None, None, None),
        ("api_down", "API down", f'count(cohesity_up{{{S}}} == 0) or vector(0)', None, None, 1),
        ("checks", "Failed checks", f'count(cohesity_check_success{{{S}}} == 0) or vector(0)', None, None, 1),
        ("groups", "Groups failing", f'count(cohesity_group_last_run_ok{{{S}}} == 0) or vector(0)', None, None, 1),
        ("sla", "SLA violations", f'sum(cohesity_group_last_run_sla_violated{{{S}}}) or vector(0)', None, 1, None),
        ("critical", "Critical alerts open", f'sum(cohesity_alerts_open{{{S},severity="critical"}}) or vector(0)', None, None, 1),
        ("hardware", "Nodes out / disks offline", f'(count(cohesity_node_in_cluster{{{S}}} == 0) or vector(0)) + (sum(cohesity_node_offline_disks{{{S}}}) or vector(0))', None, 1, None),
        ("lastrun", "Collector last run", 'time() - cohesity_collector_last_run_timestamp_seconds', "s", 600, 900),
    ]
    if html:
        d.cards(estate, "Estate", desc="Estate health at a glance. A tile turns orange or red at the same thresholds as the stat row of the plain Fleet dashboard; "
                             "'Groups failing' counts protection groups whose last backup run failed; 'Collector last run' is the time since the collector last completed a full run.")
    else:
        d.row("Estate")
        for key, title, expr, unit, warn, crit in estate:
            steps = BLUE if warn is None and crit is None else [{"color": "green", "value": None}]
            if warn is not None:
                steps = steps + [{"color": "orange", "value": warn}]
            if crit is not None:
                steps = steps + [{"color": "red", "value": crit}]
            d.stat(title, [(expr, None)], unit, w=3, thresholds=steps, decimals=0 if unit is None else None,
                   desc="Time since the collector last completed a full run." if key == "lastrun" else None)

    zero = f'0 * max by (cluster) (cohesity_up{{{S}}})'
    d.row("Clusters")
    d.table("Fleet status", [
        f'max by (cluster) (cohesity_up{{{S}}})',
        f'sum by (cluster) (1 - cohesity_check_success{{{S}}})',
        f'100 * max by (cluster) (cohesity_storage_used_bytes{{{S}}}) / max by (cluster) (cohesity_storage_capacity_bytes{{{S}}})',
        f'max by (cluster) (cohesity_cluster_data_reduction_ratio{{{S}}})',
        f'sum by (cluster) (1 - cohesity_group_last_run_ok{{{S}}}) or {zero}',
        f'sum by (cluster) (cohesity_group_last_run_sla_violated{{{S}}}) or {zero}',
        f'sum by (cluster) (cohesity_group_runs_24h{{{S},status="failed"}}) or {zero}',
        f'max by (cluster) (cohesity_runs_active{{{S}}})',
        f'sum by (cluster) (cohesity_alerts_open{{{S},severity="critical"}})',
        f'sum by (cluster) (cohesity_alerts_open{{{S},severity="warning"}})',
        f'(count by (cluster) (cohesity_node_in_cluster{{{S}}} == 0) or {zero}) + (sum by (cluster) (cohesity_node_offline_disks{{{S}}}) or {zero})',
        f'max by (cluster) (cohesity_cluster_stopped_services{{{S}}})',
        f'max by (cluster) (abs(cohesity_time_offset_seconds{{{S}}}))',
        f'max by (cluster, version) (cohesity_info{{{S}}})',
    ], rename={"A": "API", "B": "Failed checks", "C": "Used %", "D": "Reduction", "E": "Groups failing", "F": "SLA missed", "G": "Failed runs 24h",
               "H": "Running", "I": "Critical alerts", "J": "Warning alerts", "K": "Nodes/disks out", "L": "Stopped services", "M": "Clock offset", "N": None},
        units={"Clock offset": "s", "Reduction": "none"}, bool_cols=["API"], bar_cols={"Used %": (0, 100)},
        order=["cluster", "API", "Failed checks", "Used %", "Reduction", "Groups failing", "SLA missed", "Failed runs 24h", "Running", "Critical alerts", "Warning alerts",
               "Nodes/disks out", "Stopped services", "Clock offset", "version"],
        sort=("Failed checks", True), h=10, links=[{"title": "Open instance", "url": INSTANCE_URL}], filterable=True,
        desc="Used % is local storage used / total capacity (v2 cluster-storage). Reduction is the cluster data reduction ratio (N:1). Groups failing counts groups whose last backup run failed; "
             "SLA missed counts groups whose last run missed its SLA. Nodes/disks out adds nodes not in the cluster and offline disks.")

    d.row("Trends")
    d.ts("Storage used %", [(f'100 * cohesity_storage_used_bytes{{{S}}} / cohesity_storage_capacity_bytes{{{S}}}', "{{cluster}}")], "percent", w=12)
    d.ts("Cluster throughput (read + write)", [(f'sum by (cluster) (cohesity_cluster_throughput_bytes_per_second{{{S}}})', "{{cluster}}")], "Bps", w=12)
    d.ts("Backup runs in progress", [(f'cohesity_runs_active{{{S}}}', "{{cluster}}")], "none", w=12)
    d.ts("Open critical and warning alerts", [(f'sum by (cluster) (cohesity_alerts_open{{{S},severity=~"critical|warning"}})', "{{cluster}}")], "none", w=12)
    write(d, HTML_DIR if html else OUT_DIR)


# ============================================================================ Activity
def activity(html=False):
    S = 'cluster=~"$cluster"'
    d = Dashboard("Cohesity Activity", "cohesity-activity", S, "multi", refresh="30s", description="Live work across the estate: backup runs, replication, archives and recoveries.", html=html)
    d.row("Now")
    d.stat("Backup runs in progress", [(f'sum(cohesity_runs_active{{{S}}}) or vector(0)', None)], w=4)
    d.stat("Recoveries in progress", [(f'sum(cohesity_recoveries_active{{{S}}}) or vector(0)', None)], w=4)
    d.stat("Runs succeeded, 24h", [(f'sum(cohesity_runs_24h{{{S},status=~"succeeded|succeededwithwarning"}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}])
    d.stat("Runs failed, 24h", [(f'sum(cohesity_runs_24h{{{S},status=~"failed|missed|canceled"}}) or vector(0)', None)], w=4, thresholds=GREEN_RED)
    d.stat("SLA violations, 24h", [(f'sum(cohesity_group_24h_sla_violations{{{S}}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Replication / archive failures", [(f'(count(cohesity_replication_last_status{{{S},status=~"failed|canceled"}}) or vector(0)) + (count(cohesity_archive_last_status{{{S},status=~"failed|canceled"}}) or vector(0))', None)],
           w=4, thresholds=GREEN_RED, desc="Groups whose last replication or archive to a target failed.")

    d.row("Backup runs in progress")
    d.table("Running backup runs", [
        f'cohesity_run_info{{{S}}}',
        f'max by (cluster, group, run_id) (cohesity_run_progress_percent{{{S},task="backup"}})',
        f'cohesity_run_objects_done{{{S}}}',
        f'cohesity_run_objects{{{S}}}',
        f'cohesity_run_written_bytes{{{S}}}',
        f'cohesity_run_logical_bytes{{{S}}}',
        f'max by (cluster, group, run_id) (cohesity_run_remaining_seconds{{{S},task="backup"}})',
        f'cohesity_run_start_timestamp_seconds{{{S}}} * 1000',
        f'cohesity_run_first_seen_timestamp_seconds{{{S}}} * 1000',
    ], rename={"A": None, "B": "Progress %", "C": "Objects done", "D": "Objects", "E": "Written", "F": "Logical", "G": "Remaining", "H": "Started", "I": "First seen"},
        units={"Written": "bytes", "Logical": "bytes", "Remaining": "s", "Started": "dateTimeAsIso", "First seen": "dateTimeAsIso"},
        bar_cols={"Progress %": (0, 100)}, color_cols=["status"],
        order=["cluster", "group", "env", "status", "full", "Progress %", "Objects done", "Objects", "Written", "Logical", "Remaining", "Started", "First seen", "run_id"],
        sort=("Started", False), h=10, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="One row per backup run in progress (status accepted, running, on hold, finalizing, paused or canceling). Progress and remaining time come from the run's progress call, "
             "which the collector makes for up to 50 running runs per cluster. 'First seen' is when the collector first saw the run in progress.")
    d.ts("Backup runs in progress by cluster", [(f'cohesity_runs_active{{{S}}}', "{{cluster}}")], "none", w=12, h=7, stack=True)
    d.ts("Cluster write throughput", [(f'cohesity_cluster_throughput_bytes_per_second{{{S},op="write"}}', "{{cluster}}")], "Bps", w=12, h=7)

    d.row("Last 24 hours by protection group")
    d.table("Runs per group, last 24 hours", [
        f'sum by (cluster, group) (cohesity_group_runs_24h{{{S},status=~"succeeded|succeededwithwarning"}})',
        f'sum by (cluster, group) (cohesity_group_runs_24h{{{S},status=~"failed|missed|canceled"}})',
        f'cohesity_group_24h_sla_violations{{{S}}}',
        f'cohesity_group_24h_written_bytes{{{S}}}',
        f'cohesity_group_24h_logical_bytes{{{S}}}',
        f'max by (cluster, group) (cohesity_group_last_run_status{{{S}}} == 1)',
    ], rename={"A": "Succeeded", "B": "Failed", "C": "SLA missed", "D": "Written", "E": "Logical", "F": None},
        units={"Written": "bytes", "Logical": "bytes"}, order=["cluster", "group", "Succeeded", "Failed", "SLA missed", "Written", "Logical"],
        sort=("Failed", True), w=14, h=12, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="Runs started in the last 24 hours (v2 runs summary). Written is the data written after reduction; Logical is the logical size protected.")
    d.ts("Runs started in the last 24 hours, by status", [(f'sum by (status) (cohesity_runs_24h{{{S}}})', "{{status}}")], "none", w=10, h=12, stack=True)

    d.row("Replication and archive (each group's last run)")
    d.table("Replication", [
        f'cohesity_replication_last_status{{{S}}}',
        f'cohesity_replication_last_percent{{{S}}}',
        f'cohesity_replication_last_logical_bytes{{{S}}}',
        f'cohesity_replication_last_physical_bytes{{{S}}}',
        f'cohesity_replication_last_end_timestamp_seconds{{{S}}} * 1000',
        f'cohesity_replication_last_sla_violated{{{S}}}',
    ], rename={"A": None, "B": "Progress %", "C": "Logical", "D": "Sent", "E": "Ended", "F": "SLA missed"},
        units={"Logical": "bytes", "Sent": "bytes", "Ended": "dateTimeAsIso"}, bar_cols={"Progress %": (0, 100)}, color_cols=["status"],
        order=["cluster", "group", "target", "status", "Progress %", "Logical", "Sent", "Ended", "SLA missed"], sort=("Ended", True), w=12, h=10, filterable=True)
    d.table("Archive", [
        f'cohesity_archive_last_status{{{S}}}',
        f'cohesity_archive_last_logical_bytes{{{S}}}',
        f'cohesity_archive_last_transfer_rate_bytes_per_second{{{S}}}',
        f'cohesity_archive_last_end_timestamp_seconds{{{S}}} * 1000',
        f'cohesity_archive_last_sla_violated{{{S}}}',
    ], rename={"A": None, "B": "Logical", "C": "Rate", "D": "Ended", "E": "SLA missed"},
        units={"Logical": "bytes", "Rate": "Bps", "Ended": "dateTimeAsIso"}, color_cols=["status"],
        order=["cluster", "group", "target", "target_type", "status", "Logical", "Rate", "Ended", "SLA missed"], sort=("Ended", True), w=12, h=10, filterable=True)

    d.row("Recoveries")
    d.table("Recoveries in progress", [f'cohesity_recovery_info{{{S}}} * 1000'], rename={"A": "Started"}, units={"Started": "dateTimeAsIso"}, color_cols=["status"],
            order=["cluster", "name", "action", "env", "status", "user", "Started"], sort=("Started", False), w=14, h=8, filterable=True,
            desc="Recoveries started in the last 24 hours that are still running.")
    d.table("Recoveries, last 24 hours", [f'cohesity_recoveries_24h{{{S}}}'], rename={"A": "Recoveries"}, color_cols=["status"],
            order=["cluster", "action", "status", "Recoveries"], sort=("cluster", False), w=10, h=8)
    write(d, HTML_DIR if html else OUT_DIR)


# ============================================================================ Instance
def instance(html=False):
    S = 'cluster="$cluster"'
    d = Dashboard("Cohesity Instance", "cohesity-instance", S, "single", description="Everything about one cluster. Pick the cluster at the top.", html=html)
    d.row("Health")
    d.stat("API", [(f'cohesity_up{{{S}}}', None)], w=3, mappings=OKFAIL, thresholds=RED_GREEN)
    d.stat("Failed checks", [(f'count(cohesity_check_success{{{S}}} == 0) or vector(0)', None)], w=3, thresholds=GREEN_RED)
    d.stat("Nodes", [(f'cohesity_cluster_nodes{{{S}}}', None)], w=3)
    d.stat("Nodes out / disks offline", [(f'(count(cohesity_node_in_cluster{{{S}}} == 0) or vector(0)) + (sum(cohesity_node_offline_disks{{{S}}}) or vector(0))', None)], w=3,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Stopped services", [(f'cohesity_cluster_stopped_services{{{S}}}', None)], w=3, thresholds=GREEN_RED)
    d.stat("Critical alerts open", [(f'sum(cohesity_alerts_open{{{S},severity="critical"}}) or vector(0)', None)], w=3, thresholds=GREEN_RED, decimals=0)
    d.stat("Clock offset", [(f'cohesity_time_offset_seconds{{{S}}}', None)], "s", w=3, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 60}])
    d.stat("Collected", [(f'time() - cohesity_check_last_success_timestamp_seconds{{{S},check="cluster"}}', None)], "s", w=3,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 600}, {"color": "red", "value": 900}], desc="Time since this cluster was last collected.")
    d.table("Cluster", [f'cohesity_info{{{S}}}', f'cohesity_cluster_encryption_enabled{{{S}}}', f'cohesity_cluster_services_synced{{{S}}}', f'cohesity_cluster_operation{{{S}}}'],
            rename={"A": None, "B": "Encryption", "C": "Services synced", "D": None}, bool_cols=["Encryption", "Services synced"], h=4,
            order=["cluster", "name", "id", "version", "patch", "type", "deployment", "operation", "Encryption", "Services synced"])

    d.row("Capacity")
    d.stat("Used", [(f'100 * cohesity_storage_used_bytes{{{S}}} / cohesity_storage_capacity_bytes{{{S}}}', None)], "percent", w=4, decimals=1,
           thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}])
    d.stat("Available", [(f'cohesity_storage_available_bytes{{{S}}}', None)], "bytes", w=4)
    d.stat("Days until full (30d trend)", [(f'cohesity_storage_available_bytes{{{S}}} / clamp_min(deriv(cohesity_storage_used_bytes{{{S}}}[30d:1h]), 1) / 86400', None)], "d", w=4, decimals=0,
           thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 30}, {"color": "green", "value": 90}], desc="Available space divided by the 30-day growth rate. Shows a very large number while usage is flat or falling; needs several days of data to settle.")
    d.stat("Data reduction", [(f'cohesity_cluster_data_reduction_ratio{{{S}}}', None)], None, w=4, decimals=1, desc="Logical data in / physical data written (N:1).")
    d.stat("Capacity", [(f'cohesity_storage_capacity_bytes{{{S}}}', None)], "bytes", w=4)
    d.stat("Usable after resiliency", [(f'cohesity_cluster_usable_capacity_bytes{{{S}}}', None)], "bytes", w=4, desc="Minimum usable capacity after erasure coding or replication factor.")
    d.ts("Storage used", [(f'cohesity_storage_used_bytes{{{S}}}', "used"), (f'cohesity_storage_capacity_bytes{{{S}}}', "capacity")], "bytes", w=12)
    d.ts("Used by service", [(f'cohesity_storage_service_bytes{{{S},kind="physical"}}', "{{service}}")], "bytes", w=12, stack=True)
    d.table("Storage domains", [
        f'cohesity_storage_domain_info{{{S}}}',
        f'max by (cluster, domain) (cohesity_storage_domain_bytes{{{S},kind="local_physical"}})',
        f'max by (cluster, domain) (cohesity_storage_domain_bytes{{{S},kind="logical"}})',
        f'max by (cluster, domain) (cohesity_storage_domain_bytes{{{S},kind="data_in"}}) / max by (cluster, domain) (cohesity_storage_domain_bytes{{{S},kind="data_written"}} > 0)',
        f'cohesity_storage_domain_quota_bytes{{{S}}}',
        f'cohesity_storage_domain_files{{{S}}}',
    ], rename={"A": None, "B": "Physical used", "C": "Logical", "D": "Reduction", "E": "Quota", "F": "Files"}, units={"Physical used": "bytes", "Logical": "bytes", "Quota": "bytes", "Reduction": "none"},
        hide=["cluster", "domain_id"], order=["domain", "Physical used", "Logical", "Reduction", "Quota", "Files", "partition", "encryption", "node_failures_tolerated", "disk_failures_tolerated"], h=6)

    d.row("Performance")
    d.ts("Throughput", [(f'cohesity_cluster_throughput_bytes_per_second{{{S}}}', "{{op}}")], "Bps", w=8)
    d.ts("IOPS", [(f'cohesity_cluster_iops{{{S}}}', "{{op}}")], "iops", w=8)
    d.ts("Latency", [(f'cohesity_cluster_latency_seconds{{{S}}}', "{{op}}")], "s", w=8)

    d.row("Protection")
    d.stat("Protection groups", [(f'count(cohesity_group_info{{{S}}}) or vector(0)', None)], w=4)
    d.stat("Last run failed", [(f'count(cohesity_group_last_run_ok{{{S}}} == 0) or vector(0)', None)], w=4, thresholds=GREEN_RED)
    d.stat("Last run missed SLA", [(f'sum(cohesity_group_last_run_sla_violated{{{S}}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Paused groups", [(f'sum(cohesity_group_paused{{{S}}}) or vector(0)', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Runs in progress", [(f'cohesity_runs_active{{{S}}}', None)], w=4)
    d.stat("Unprotected objects", [(f'cohesity_objects{{{S},protected="no"}}', None)], w=4, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}],
           desc="Objects on registered sources that no protection group covers.")
    d.table("Protection groups", [
        f'cohesity_group_info{{{S}}}',
        f'max by (cluster, group, status) (cohesity_group_last_run_status{{{S}}} == 1)',
        f'cohesity_group_last_run_end_timestamp_seconds{{{S}}} * 1000',
        f'cohesity_group_last_run_duration_seconds{{{S}}}',
        f'max by (cluster, group) (cohesity_group_last_run_objects{{{S},result="failed"}})',
        f'cohesity_group_last_run_written_bytes{{{S}}}',
        f'cohesity_group_last_run_sla_violated{{{S}}}',
        f'cohesity_group_paused{{{S}}}',
        f'cohesity_group_protected_objects{{{S}}}',
    ], rename={"A": None, "B": None, "C": "Last run ended", "D": "Duration", "E": "Failed objects", "F": "Written", "G": "SLA missed", "H": "Paused", "I": "Objects"},
        units={"Last run ended": "dateTimeAsIso", "Duration": "s", "Written": "bytes"}, color_cols=["status"], hide=["cluster", "group_id"],
        order=["group", "env", "policy", "status", "Last run ended", "Duration", "Objects", "Failed objects", "Written", "SLA missed", "Paused", "domain", "priority"],
        sort=("status", False), h=12, filterable=True, desc="Status is the last backup run's (a running run shows running). The full run history is in the cluster UI.")
    d.table("Failed objects (last run of failed or warned groups)", [f'cohesity_failed_object_info{{{S}}} * 1000'], rename={"A": "When"}, units={"When": "dateTimeAsIso"},
            color_cols=["result"], order=["When", "group", "object", "env", "source", "result", "attempts", "message"], hide=["cluster"], sort=("When", True), h=8, filterable=True,
            desc="Capped at 200 objects across 20 groups per collector run. Get-CohesityFailedObjects.ps1 lists them all as CSV.")
    d.table("Replication and archive targets (last run)", [
        f'label_replace(cohesity_replication_last_status{{{S}}}, "task", "replication", "", "") or label_replace(cohesity_archive_last_status{{{S}}}, "task", "archive", "", "")',
    ], rename={"A": None}, color_cols=["status"], hide=["cluster", "target_type"], order=["task", "group", "target", "status"], sort=("status", False), w=12, h=8, filterable=True)
    d.ts("Runs started in the last 24 hours, by status", [(f'sum by (status) (cohesity_group_runs_24h{{{S}}})', "{{status}}")], "none", w=12, h=8, stack=True)

    d.row("Nodes")
    d.table("Nodes", [
        f'cohesity_node_info{{{S}}}',
        f'100 * cohesity_node_used_bytes{{{S}}} / cohesity_node_capacity_bytes{{{S}}}',
        f'cohesity_node_capacity_bytes{{{S}}}',
        f'cohesity_node_offline_disks{{{S}}}',
        f'max by (cluster, node, state) (cohesity_node_removal{{{S}}})',
    ], rename={"A": None, "B": "Used %", "C": "Capacity", "D": "Offline disks", "E": None}, units={"Capacity": "bytes"}, bar_cols={"Used %": (0, 100)}, color_cols=["state"],
        hide=["cluster", "node_id"], order=["node", "ip", "model", "hardware", "serial", "version", "Used %", "Capacity", "Offline disks", "state", "type"], h=7)

    d.row("Sources, targets and licence")
    d.table("Registered sources", [f'cohesity_source_status{{{S}}}', f'cohesity_source_last_refresh_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": None, "B": "Last refresh"}, units={"Last refresh": "dateTimeAsIso"}, color_cols=["status"], hide=["cluster"], order=["source", "env", "status", "Last refresh"], w=12, h=8, filterable=True)
    d.table("Objects by environment", [f'cohesity_objects_by_env{{{S},protected="yes"}}', f'cohesity_objects_by_env{{{S},protected="no"}}'],
            rename={"A": "Protected", "B": "Unprotected"}, hide=["cluster", "protected"], order=["env", "Protected", "Unprotected"], sort=("Unprotected", True), w=6, h=8)
    d.table("Archive targets", [f'cohesity_external_target_info{{{S}}}', f'max by (cluster, target) (cohesity_vault_usage_bytes{{{S}}})'],
            rename={"A": None, "B": "Stored"}, units={"Stored": "bytes"}, color_cols=["status"], hide=["cluster", "target_id", "ownership"], w=6, h=8)
    d.table("Remote clusters", [f'cohesity_remote_cluster_info{{{S}}}', f'cohesity_remote_cluster_tls_enabled{{{S}}}'], rename={"A": None, "B": "TLS"}, bool_cols=["TLS"],
            hide=["cluster", "remote_id"], w=8, h=6)
    d.table("Licence", [f'cohesity_license_entitled_gib{{{S}}}', f'cohesity_license_used_gib{{{S}}}', f'(cohesity_license_expiry_timestamp_seconds{{{S}}} - time()) / 86400'],
            rename={"A": "Entitled GiB", "B": "Used GiB", "C": "Days to expiry"}, units={"Days to expiry": "d"}, hide=["cluster"], w=8, h=6)
    d.table("SmartFiles views", [f'cohesity_views{{{S}}}'], rename={"A": "Views"}, hide=["cluster"], w=8, h=6)

    d.row("Alerts")
    d.ts("New alerts per hour by severity", [(f'sum by (severity) (increase(cohesity_alerts_total{{{S}}}[1h]))', "{{severity}}")], "none", w=24, h=6, bars=True, stack=True)
    d.table("Open critical and warning alerts", [f'cohesity_alert_recent{{{S}}} * 1000'], rename={"A": "Latest"}, units={"Latest": "dateTimeAsIso"}, color_cols=["severity"],
            order=["Latest", "severity", "category", "name", "message", "occurrences", "code", "id"], hide=["cluster"], sort=("Latest", True), h=10, filterable=True,
            desc="The 20 newest open critical and warning alerts. Every new alert, info included, is archived daily under events\\ on the monitoring host.")

    d.row("Collector")
    d.stat("Package version", [('cohesity_collector_info', '{{version}}')], w=6, text_mode="name", thresholds=BLUE, desc="Version of the installed Cohesity monitoring package (VERSION file in the install folder).")
    d.stat("Last collector run", [('cohesity_collector_last_run_timestamp_seconds * 1000', None)], "dateTimeAsIso", w=6, thresholds=BLUE)
    d.stat("Checks failing", [(f'count(cohesity_check_success{{{S}}} == 0) or vector(0)', None)], w=6, decimals=0, thresholds=GREEN_RED)
    d.stat("Collection time", [(f'cohesity_collect_duration_seconds{{{S}}}', None)], "s", w=6, thresholds=BLUE, decimals=1)
    d.table("Checks", [f'cohesity_check_success{{{S}}}', f'cohesity_check_last_success_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": "OK", "B": "Last success"}, units={"Last success": "dateTimeAsIso"}, bool_cols=["OK"], hide=["cluster"], sort=("OK", False), w=12, h=12)
    d.ts("Collection time", [(f'cohesity_collect_duration_seconds{{{S}}}', "seconds")], "s", w=12, h=12)
    write(d, HTML_DIR if html else OUT_DIR)


# ============================================================================ Patch management
def patches(html=False):
    S = 'cluster=~"$cluster"'
    d = Dashboard("Cohesity Patch Management", "cohesity-patches", S, "multi", time_from="now-7d", refresh="5m", description="Software versions, patches, node hardware and licences across the estate.", html=html)
    d.row("Versions")
    d.stat("Clusters per version", [(f'count by (version) (cohesity_info{{{S}}})', "{{version}}")], w=8, thresholds=BLUE)
    d.stat("Clusters per patch", [(f'count by (patch) (label_replace(cohesity_info{{{S}}}, "patch", "none", "patch", ""))', "{{patch}}")], w=8, thresholds=BLUE)
    d.stat("Nodes per model", [(f'count by (model) (cohesity_node_info{{{S}}})', "{{model}}")], w=8, thresholds=BLUE)
    d.table("Clusters", [
        f'max by (cluster, name, version, patch, type, deployment) (cohesity_info{{{S}}})',
        f'max by (cluster) (cohesity_patches_installed{{{S}}})',
        f'max by (cluster) (cohesity_patches_available{{{S}}})',
        f'max by (cluster) (cohesity_cluster_nodes{{{S}}})',
        f'max by (cluster) (cohesity_cluster_upgrade_aborted{{{S}}})',
        f'max by (cluster) (cohesity_cluster_patch_apply_aborted{{{S}}})',
        f'max by (cluster) (cohesity_time_offset_seconds{{{S}}})',
        f'max by (cluster) (cohesity_cluster_encryption_enabled{{{S}}})',
    ], rename={"A": None, "B": "Patches applied", "C": "Patches available", "D": "Nodes", "E": "Upgrade aborted", "F": "Patch aborted", "G": "Clock offset", "H": "Encryption"},
        units={"Clock offset": "s"}, bool_cols=["Encryption"],
        order=["cluster", "name", "version", "patch", "Patches applied", "Patches available", "Nodes", "Upgrade aborted", "Patch aborted", "Clock offset", "Encryption", "type", "deployment"],
        sort=("version", False), h=7, filterable=True, links=[{"title": "Open instance", "url": INSTANCE_URL}],
        desc="Version is the cluster software version; patch is the applied service patch level. Patches available counts patches already downloaded to the cluster and ready to apply.")
    d.row("Patches and nodes")
    d.table("Applied patches", [f'cohesity_patch_info{{{S}}} * 1000'], rename={"A": "Applied"}, units={"Applied": "dateTimeAsIso"}, order=["cluster", "service", "version", "level", "Applied"],
            sort=("cluster", False), h=10, filterable=True, w=12)
    d.table("Node software and uptime", [f'cohesity_node_status_info{{{S}}}', f'cohesity_node_last_upgrade_timestamp_seconds{{{S}}} * 1000'],
            rename={"A": None, "B": "Last upgrade"}, units={"Last upgrade": "dateTimeAsIso"}, hide=["node_id", "operation"], order=["cluster", "ip", "version", "uptime", "Last upgrade"],
            sort=("cluster", False), h=10, filterable=True, w=12)
    d.table("Node hardware", [f'cohesity_node_info{{{S}}}'], rename={"A": None}, hide=["node_id"], order=["cluster", "node", "ip", "model", "hardware", "serial", "version", "type"],
            sort=("cluster", False), h=10, filterable=True)
    d.row("Licences")
    d.table("Licence by feature", [f'cohesity_license_entitled_gib{{{S}}}', f'cohesity_license_used_gib{{{S}}}', f'100 * cohesity_license_used_gib{{{S}}} / cohesity_license_entitled_gib{{{S}}}',
                                   f'(cohesity_license_expiry_timestamp_seconds{{{S}}} - time()) / 86400'],
            rename={"A": "Entitled GiB", "B": "Used GiB", "C": "Used %", "D": "Days to expiry"}, units={"Days to expiry": "d"}, bar_cols={"Used %": (0, 100)},
            order=["cluster", "feature", "Entitled GiB", "Used GiB", "Used %", "Days to expiry"], sort=("Days to expiry", False), h=10, filterable=True,
            desc="From v1 licenseUsage. Over 100% means the feature uses more than its entitlement.")
    write(d, HTML_DIR if html else OUT_DIR)


# ============================================================================ Alerts
def alerts(html=False):
    S = 'cluster=~"$cluster"'
    d = Dashboard("Cohesity Alerts", "cohesity-alerts", S, "multi", description="Cluster alerts across the estate. Informational alerts are counted but not listed.", html=html)
    d.row("Open now")
    d.stat("Critical", [(f'sum(cohesity_alerts_open{{{S},severity="critical"}}) or vector(0)', None)], w=6, decimals=0, thresholds=GREEN_RED)
    d.stat("Warning", [(f'sum(cohesity_alerts_open{{{S},severity="warning"}}) or vector(0)', None)], w=6, decimals=0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}])
    d.stat("Info", [(f'sum(cohesity_alerts_open{{{S},severity="info"}}) or vector(0)', None)], w=6, decimals=0, thresholds=BLUE)
    d.stat("New in the last 24 hours", [(f'sum(increase(cohesity_alerts_total{{{S}}}[24h])) or vector(0)', None)], w=6, decimals=0, thresholds=BLUE)
    d.ts("New alerts per hour by severity", [(f'sum by (severity) (increase(cohesity_alerts_total{{{S},severity!="info"}}[1h]))', "{{severity}}")], "none", w=12, h=7, bars=True, stack=True)
    d.ts("Open critical and warning alerts by cluster", [(f'sum by (cluster) (cohesity_alerts_open{{{S},severity=~"critical|warning"}})', "{{cluster}}")], "none", w=12, h=7)
    d.row("Open alerts")
    d.table("Critical and warning (20 newest per cluster)", [f'cohesity_alert_recent{{{S}}} * 1000'], rename={"A": "Latest"}, units={"Latest": "dateTimeAsIso"}, color_cols=["severity"],
            order=["Latest", "cluster", "severity", "category", "name", "message", "occurrences", "code", "id"], sort=("Latest", True), h=11, filterable=True,
            links=[{"title": "Open instance", "url": INSTANCE_URL}],
            desc="Filter any column with the funnel icon. Every new alert, info included, is archived daily under events\\ on the monitoring host.")
    d.table("Open alerts by category", [f'cohesity_alerts_open_by_category{{{S}}}'], rename={"A": "Open"}, color_cols=["severity"], order=["cluster", "severity", "category", "Open"],
            sort=("Open", True), w=12, h=8)
    d.table("Alerts active in the last 24 hours, by type", [f'cohesity_alerts_active{{{S}}} > 0'], rename={"A": "Alerts"}, color_cols=["severity"], order=["cluster", "bucket", "severity", "Alerts"],
            sort=("Alerts", True), w=12, h=8, desc="From v1 stats/alerts: hardware, software, data service and maintenance alerts.")
    write(d, HTML_DIR if html else OUT_DIR)


if __name__ == '__main__':
    os.makedirs(HTML_DIR, exist_ok=True)
    for build in (fleet, activity, instance, patches, alerts):
        build()
        build(html=True)
