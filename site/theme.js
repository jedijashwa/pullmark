/* Appearance toggle (spec: site-dark-mode). Three states: automatic
   (follow the system), forced light, forced dark. The choice persists
   as pm-theme in localStorage and is applied as data-theme on <html>
   BEFORE first paint — this script is included without defer, right
   after the theme-color metas, and the token blocks in every
   stylesheet honor [data-theme] alongside prefers-color-scheme.
   No-JS visitors simply keep the automatic behavior. */
(function () {
  "use strict";

  var KEY = "pm-theme";

  function read() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function store(value) {
    try {
      if (value) { localStorage.setItem(KEY, value); }
      else { localStorage.removeItem(KEY); }
    } catch (e) { /* private mode */ }
  }

  var mode = read();
  if (mode !== "light" && mode !== "dark") { mode = "auto"; }
  if (mode !== "auto") {
    document.documentElement.setAttribute("data-theme", mode);
  }

  var LABELS = {
    "en":      { auto: "Appearance: automatic", light: "Appearance: light", dark: "Appearance: dark" },
    "zh-Hans": { auto: "外观：自动", light: "外观：浅色", dark: "外观：深色" },
    "ja":      { auto: "外観：自動", light: "外観：ライト", dark: "外観：ダーク" },
    "fr":      { auto: "Apparence : automatique", light: "Apparence : claire", dark: "Apparence : sombre" },
    "de":      { auto: "Erscheinungsbild: automatisch", light: "Erscheinungsbild: hell", dark: "Erscheinungsbild: dunkel" },
    "nl":      { auto: "Weergave: automatisch", light: "Weergave: licht", dark: "Weergave: donker" },
    "es":      { auto: "Apariencia: automática", light: "Apariencia: clara", dark: "Apariencia: oscura" },
    "pt-BR":   { auto: "Aparência: automática", light: "Aparência: clara", dark: "Aparência: escura" }
  };

  var ICONS = {
    auto: '<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M8 1.8a6.2 6.2 0 0 1 0 12.4z" fill="currentColor"/></svg>',
    light: '<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3.4" fill="none" stroke="currentColor" stroke-width="1.4"/><g stroke="currentColor" stroke-width="1.3" stroke-linecap="round"><path d="M8 .9v1.8M8 13.3v1.8M.9 8h1.8M13.3 8h1.8M2.98 2.98l1.27 1.27M11.75 11.75l1.27 1.27M13.02 2.98l-1.27 1.27M4.25 11.75l-1.27 1.27"/></g></svg>',
    dark: '<svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true"><path d="M13.8 9.6A6.3 6.3 0 0 1 6.4 2.2a6.3 6.3 0 1 0 7.4 7.4z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>'
  };

  var STYLE = ".theme-toggle{display:inline-flex;align-items:center;justify-content:center;" +
    "width:30px;height:30px;margin-left:2px;padding:0;border:0;border-radius:7px;" +
    "background:none;color:var(--muted);cursor:pointer}" +
    ".theme-toggle:hover{color:var(--ink);background:var(--line-soft)}" +
    ".theme-toggle svg{display:block}";

  function labels() {
    var lang = document.documentElement.getAttribute("lang") || "en";
    return LABELS[lang] || LABELS.en;
  }

  // Dark screenshot <source> elements and the theme-color metas follow
  // the forced theme; automatic restores their media queries.
  function syncMedia() {
    var dark = "(prefers-color-scheme: dark)";
    var light = "(prefers-color-scheme: light)";
    document.querySelectorAll("picture source[data-pm-dark]").forEach(function (source) {
      source.setAttribute("media",
        mode === "dark" ? "all" : mode === "light" ? "not all" : dark);
    });
    document.querySelectorAll('meta[name="theme-color"]').forEach(function (meta) {
      var own = meta.getAttribute("data-pm-scheme")
        || (meta.getAttribute("media") === light ? "light" : "dark");
      meta.setAttribute("data-pm-scheme", own);
      if (mode === "auto") {
        meta.setAttribute("media", own === "light" ? light : dark);
      } else {
        // The forced scheme's meta must win: make it unconditional and
        // sideline the other.
        meta.setAttribute("media", own === mode ? "all" : "not all");
      }
    });
  }

  function paintButton(button) {
    button.innerHTML = ICONS[mode];
    button.setAttribute("aria-label", labels()[mode]);
    button.title = labels()[mode];
  }

  function apply(next, button) {
    mode = next;
    store(next === "auto" ? null : next);
    if (next === "auto") {
      document.documentElement.removeAttribute("data-theme");
    } else {
      document.documentElement.setAttribute("data-theme", next);
    }
    syncMedia();
    if (button) { paintButton(button); }
  }

  function init() {
    var style = document.createElement("style");
    style.textContent = STYLE;
    document.head.append(style);

    var nav = document.querySelector(".nav .links") || document.querySelector(".nav");
    if (nav) {
      var button = document.createElement("button");
      button.className = "theme-toggle";
      button.type = "button";
      paintButton(button);
      button.addEventListener("click", function () {
        apply(mode === "auto" ? "light" : mode === "light" ? "dark" : "auto", button);
      });
      nav.append(button);
    }
    syncMedia();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
