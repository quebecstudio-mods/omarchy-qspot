.pragma library

// The web for qSpot: bangs ("!yt bubble tea"), addresses ("quebec.studio/lab",
// "site.test"), and a search on the web as the last row. Nothing is sent
// anywhere before Enter: these functions only build the address to open.

// Search engines by name; "searchEngine" may also be an address with %s.
var ENGINES = {
  duckduckgo: { name: "DuckDuckGo", url: "https://duckduckgo.com/?q=%s" },
  google: { name: "Google", url: "https://www.google.com/search?q=%s" },
  bing: { name: "Bing", url: "https://www.bing.com/search?q=%s" },
  kagi: { name: "Kagi", url: "https://kagi.com/search?q=%s" },
  startpage: { name: "Startpage", url: "https://www.startpage.com/do/search?query=%s" },
  ecosia: { name: "Ecosia", url: "https://www.ecosia.org/search?q=%s" },
  brave: { name: "Brave Search", url: "https://search.brave.com/search?q=%s" },
  qwant: { name: "Qwant", url: "https://www.qwant.com/?q=%s" }
}

// Endings that read as a file before a website: "README.md", "Spot.qml". Real
// top-level domains among them (.sh, .ai) stay addresses.
var FILE_ENDINGS = {
  md: true, txt: true, js: true, mjs: true, ts: true, tsx: true, jsx: true, py: true, qml: true,
  json: true, jsonc: true, php: true, lua: true, rs: true, go: true, rb: true, pl: true, css: true,
  scss: true, html: true, htm: true, xml: true, yml: true, yaml: true, toml: true, ini: true, cfg: true,
  conf: true, log: true, sql: true, csv: true, png: true, jpg: true, jpeg: true, gif: true, svg: true,
  webp: true, pdf: true, doc: true, docx: true, xls: true, xlsx: true, ppt: true, pptx: true, odt: true,
  zip: true, gz: true, tar: true, xz: true, zst: true, mp3: true, mp4: true, mkv: true, mov: true,
  wav: true, flac: true, desktop: true, lock: true, bak: true, tmp: true, env: true, twig: true,
  vue: true, svelte: true, c: true, h: true, cpp: true, hpp: true, java: true, kt: true, swift: true,
  so: true, db: true, sqlite: true, iso: true, img: true, deb: true, rpm: true, exe: true, dmg: true
}

// The engine to search with: {name, url}. setting: a name from ENGINES, or an
// address holding %s (its host is the name).
function engine(setting) {
  var value = String(setting || "").trim()
  if (ENGINES[value.toLowerCase()]) return ENGINES[value.toLowerCase()]
  if (/^https?:\/\/.*%s/.test(value)) {
    var host = /^https?:\/\/([^/]+)/.exec(value)
    return { name: host ? host[1].replace(/^www\./, "") : value, url: value }
  }
  return ENGINES.duckduckgo
}

function fill(template, terms) {
  return template.indexOf("%s") >= 0
    ? template.split("%s").join(encodeURIComponent(terms))
    : template
}

// DuckDuckGo's bangs, from qSpot's copy of their list (bin/qspot-bangs):
// {list: [[trigger, name, domain, address]], at: {trigger: index}}, the most
// used first; null until it is downloaded.
function bangTable(rows) {
  var at = {}
  for (var i = 0; i < rows.length; i++) at[rows[i][0]] = i
  return { list: rows, at: at }
}

function hostOf(url) {
  var m = /^https?:\/\/([^/?#:]+)/i.exec(String(url || ""))
  return m ? m[1].toLowerCase() : ""
}

// A bang by its trigger: {bang, name, url, domain, custom}, the url holding %s
// where the terms go; or null. shortcuts: the user's own,
// {"w": "https://en.wikipedia.org/w/index.php?search=%s"} or
// {"w": {"name": "Wikipedia", "url": "…", "home": "…"}}; they come before
// DuckDuckGo's, and their triggers are read in any case. "home" is what the
// bang opens with nothing typed after it, for an address where %s is part of
// the site ("http://%s.localhost").
function lookup(key, shortcuts, table) {
  key = String(key || "").toLowerCase()
  var own = ownFor(key, shortcuts)
  if (own) return ownBang(key, own)
  if (table && Object.prototype.hasOwnProperty.call(table.at, key)) return duckBang(table.list[table.at[key]])
  return null
}

function ownFor(key, shortcuts) {
  if (!shortcuts || typeof shortcuts !== "object") return null
  for (var name in shortcuts)
    if (Object.prototype.hasOwnProperty.call(shortcuts, name) && name.toLowerCase() === key) return shortcuts[name]
  return null
}

function ownBang(key, own) {
  var url = typeof own === "string" ? own : String(own && own.url || "")
  if (!/^https?:\/\//i.test(url)) return null
  var host = hostOf(url)
  if (host.indexOf("%s") >= 0) host = ""
  var name = typeof own === "object" && own.name ? String(own.name) : host.replace(/^www\./, "") || key
  var home = typeof own === "object" && /^https?:\/\//i.test(String(own.home || "")) ? String(own.home) : ""
  return { bang: key, name: name, url: url, domain: host, home: home, custom: true }
}

function duckBang(row) {
  return { bang: row[0], name: row[1], url: row[3].split("{{{s}}}").join("%s"), domain: row[2] || hostOf(row[3]), custom: false }
}

// The address to open for a bang and what follows it. With nothing typed, the
// site itself, as DuckDuckGo does; "" when there is none (%s in the host and
// no "home"): the bang then needs terms.
function bangUrl(found, terms) {
  terms = String(terms || "").trim()
  if (terms === "" && found.home) return found.home
  if (terms === "" && found.url.indexOf("%s") >= 0) {
    if (found.domain !== "") return "https://" + found.domain
    var site = /^(https?:\/\/[^/]+)/.exec(found.url)
    return site && site[1].indexOf("%s") < 0 ? site[1] : ""
  }
  return fill(found.url, terms)
}

// Bangs for what is typed after "!", for suggestions: the user's own whose
// trigger starts with it first, then DuckDuckGo's whose trigger or name
// starts with it, the most used first, one per name ("!yo" gives YouTube
// before YoChicago's own !yo, and Google Maps once, not thrice). An empty prefix lists the user's own,
// then the most used.
function suggest(prefix, shortcuts, table, limit) {
  prefix = String(prefix || "").toLowerCase()
  var out = []
  var taken = {}
  function add(found) {
    if (!found || out.length >= limit) return
    var key = "name:" + found.name.toLowerCase()
    if (taken[found.bang] || taken[key]) return
    out.push(found)
    taken[found.bang] = taken[key] = true
  }
  var own = shortcuts && typeof shortcuts === "object" ? Object.keys(shortcuts).sort() : []
  for (var i = 0; i < own.length; i++)
    if (own[i].toLowerCase().indexOf(prefix) === 0) add(ownBang(own[i].toLowerCase(), shortcuts[own[i]]))
  if (!table) return out
  for (var j = 0; j < table.list.length && out.length < limit; j++) {
    var row = table.list[j]
    if (row[0].indexOf(prefix) === 0 || row[1].toLowerCase().indexOf(prefix) === 0) add(duckBang(row))
  }
  return out
}

// A bang qSpot does not know (its list is not there yet, or DuckDuckGo added
// it since): DuckDuckGo itself sorts it out.
function unknownBang(query) {
  return "https://duckduckgo.com/?q=" + encodeURIComponent(String(query || "").trim())
}

// An address to open: {label, url}, or null. "quebec.studio/lab",
// "https://…", "localhost:8000", "site.test" (a local site). A file name such as
// "README.md" is not one.
function address(query) {
  var q = String(query || "").trim()
  if (q === "" || /\s/.test(q)) return null
  if (/^https?:\/\/\S+$/i.test(q)) return { label: q.replace(/^https?:\/\//i, ""), url: q }
  if (/^localhost(:\d+)?(\/\S*)?$/i.test(q)) return { label: q, url: "http://" + q }
  var m = /^((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,24}))(:\d+)?(\/\S*)?$/i.exec(q)
  if (!m) return null
  var ending = m[2].toLowerCase()
  if (FILE_ENDINGS[ending] && !m[4] && !m[3]) return null
  return { label: q, url: "https://" + q }
}

// The search on the web for a query: {name, url}.
function search(query, engineSetting) {
  var e = engine(engineSetting)
  return { name: e.name, url: fill(e.url, String(query || "").trim()) }
}
