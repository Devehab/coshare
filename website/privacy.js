// Privacy page: shares the language choice with the landing page (both blocks are in the HTML).
(function () {
  "use strict";
  var META = {
    ar: { title: "سياسة الخصوصية — CoShare", toggle: "English" },
    en: { title: "Privacy Policy — CoShare", toggle: "العربية" }
  };
  function storedLang() {
    try { return localStorage.getItem("coshare.lang"); } catch (e) { return null; }
  }
  function storeLang(value) {
    try { localStorage.setItem("coshare.lang", value); } catch (e) { /* private mode */ }
  }
  var lang = storedLang() || ((navigator.language || "ar").toLowerCase().indexOf("ar") === 0 ? "ar" : "en");
  var labelled = document.querySelectorAll("[data-ar][data-en]");

  function applyLang() {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
    labelled.forEach(function (el) { el.textContent = el.getAttribute("data-" + lang); });
    document.title = META[lang].title;
    document.getElementById("langToggle").textContent = META[lang].toggle;
  }

  document.getElementById("langToggle").addEventListener("click", function () {
    lang = lang === "ar" ? "en" : "ar";
    storeLang(lang);
    applyLang();
    window.scrollTo(0, 0);
  });

  var header = document.querySelector(".site-header");
  function onScroll() { header.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Phones show each table row as a card; label every value with its column's heading.
  document.querySelectorAll(".data-table").forEach(function (table) {
    var heads = table.querySelectorAll("thead th");
    table.querySelectorAll("tbody tr").forEach(function (row) {
      Array.prototype.forEach.call(row.children, function (cell, i) {
        if (heads[i]) cell.setAttribute("data-label", heads[i].textContent.trim());
      });
    });
  });

  document.getElementById("year").textContent = new Date().getFullYear();
  applyLang();
})();
