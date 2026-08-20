/* Detected-language suggestion banner (spec: site-localization).
   Distinct URLs per language; this only SUGGESTS — never redirects.
   Included solely on pages that have translated variants, so its
   presence is also the "variants exist" gate. */
(function () {
  "use strict";

  // Locale code → path prefix. English lives at the root.
  var LOCALES = {
    "zh-Hans": "zh", "ja": "ja", "fr": "fr", "de": "de",
    "nl": "nl", "es": "es", "pt-BR": "pt"
  };

  // Banner copy is written in the TARGET language — it addresses the
  // reader who'd rather be there.
  var STRINGS = {
    "en":      { msg: "This page is also available in English.", link: "View in English", close: "Dismiss" },
    "zh-Hans": { msg: "此页面提供中文版。", link: "查看中文版", close: "关闭" },
    "ja":      { msg: "このページは日本語でもご覧いただけます。", link: "日本語で表示", close: "閉じる" },
    "fr":      { msg: "Cette page est aussi disponible en français.", link: "Voir en français", close: "Fermer" },
    "de":      { msg: "Diese Seite ist auch auf Deutsch verfügbar.", link: "Auf Deutsch ansehen", close: "Schließen" },
    "nl":      { msg: "Deze pagina is ook beschikbaar in het Nederlands.", link: "In het Nederlands bekijken", close: "Sluiten" },
    "es":      { msg: "Esta página también está disponible en español.", link: "Ver en español", close: "Cerrar" },
    "pt-BR":   { msg: "Esta página também está disponível em português.", link: "Ver em português", close: "Fechar" }
  };

  var DISMISS_KEY = "pm-lang-suggest";
  var CHOICE_KEY = "pm-lang";

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }
  function read(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }

  var pageLocale = document.documentElement.getAttribute("lang") || "en";

  // The page's path with any locale prefix stripped — the English
  // address of this content.
  function basePath() {
    var path = location.pathname;
    for (var code in LOCALES) {
      var prefix = "/" + LOCALES[code] + "/";
      if (path === prefix.slice(0, -1)) { return "/"; }
      if (path.indexOf(prefix) === 0) { return path.slice(prefix.length - 1); }
    }
    return path;
  }

  function urlFor(code) {
    var base = basePath();
    return code === "en" ? base : "/" + LOCALES[code] + base;
  }

  // Best supported locale for this visitor's browser languages.
  function detect() {
    var langs = navigator.languages || [navigator.language || ""];
    for (var i = 0; i < langs.length; i++) {
      var tag = String(langs[i]).toLowerCase();
      if (tag.indexOf("en") === 0) { return "en"; }
      if (tag.indexOf("ja") === 0) { return "ja"; }
      if (tag.indexOf("fr") === 0) { return "fr"; }
      if (tag.indexOf("de") === 0) { return "de"; }
      if (tag.indexOf("nl") === 0) { return "nl"; }
      if (tag.indexOf("es") === 0) { return "es"; }
      if (tag.indexOf("pt") === 0) { return "pt-BR"; }
      // Simplified only: never offer zh-Hans to zh-TW/zh-Hant readers.
      if (tag === "zh" || tag.indexOf("zh-cn") === 0 || tag.indexOf("zh-sg") === 0
          || tag.indexOf("zh-hans") === 0) { return "zh-Hans"; }
    }
    return null;
  }

  // Any switcher click is a durable language choice.
  function rememberClicks() {
    document.querySelectorAll(".lang-switch a[hreflang]").forEach(function (a) {
      a.addEventListener("click", function () {
        store(CHOICE_KEY, a.getAttribute("hreflang"));
      });
    });
  }

  function showBanner(target) {
    var strings = STRINGS[target];
    if (!strings) { return; }
    var banner = document.createElement("div");
    banner.className = "lang-banner";
    banner.setAttribute("lang", target === "en" ? "en" : target);
    var msg = document.createElement("span");
    msg.textContent = strings.msg + " ";
    var link = document.createElement("a");
    link.href = urlFor(target);
    link.textContent = strings.link;
    link.addEventListener("click", function () { store(CHOICE_KEY, target); });
    msg.append(link);
    var close = document.createElement("button");
    close.className = "lang-banner-close";
    close.setAttribute("aria-label", strings.close);
    close.textContent = "×";
    close.addEventListener("click", function () {
      store(DISMISS_KEY, "1");
      banner.remove();
    });
    banner.append(msg, close);
    document.body.prepend(banner);
  }

  function init() {
    rememberClicks();
    if (read(DISMISS_KEY)) { return; }
    var choice = read(CHOICE_KEY);
    var target = (choice && STRINGS[choice]) ? choice : detect();
    if (!target || target === pageLocale) { return; }
    showBanner(target);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
