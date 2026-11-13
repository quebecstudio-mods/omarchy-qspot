.pragma library

// Calculations for qSpot: when a query reads as one, prepare() turns it into
// an expression for qalc (Qalculate), parse() reads qalc's answer, and basic()
// computes plain arithmetic when qalc is not installed.

// The words of a calculation are read in the user's language, from the
// plugin's catalogs (i18n/<language>.json: "calc.to", "calc.of"), and in
// English always, which qalc reads natively, as it reads symbols and codes
// ("km", "USD", "€", "→") in every language. A language without a catalog
// works in English. prepare() rewrites the user's words into English ones.
var ENGLISH = { to: ["to", "in"], of: ["of"] }
// Words a calculation may hold outside units and functions, once rewritten.
var KEYWORDS = { to: true, in: true, of: true, pi: true, e: true }
// Words after which the next word is a unit or a currency (the target).
var TARGETS = { to: true, in: true }
// qalc functions that run a program or touch files: never sent, whatever
// the query.
var UNSAFE = { command: true, load: true, export: true, plot: true }

// A letter in any script: Unicode property classes when the engine has them
// (node does; Quickshell's QML engine does not), otherwise Latin, Greek,
// Cyrillic, Hebrew, Arabic, kana, CJK and Hangul by range.
var LETTERS = (function() {
  try {
    return new RegExp("[\\p{L}\\p{M}]", "u")
  } catch (e) {
    return /[A-Za-zªµºÀ-ɏͰ-ϿЀ-ԯ֐-׿؀-ۿ぀-ヿ一-鿿가-힯]/
  }
})()
var WORDS = new RegExp(LETTERS.source + "+", LETTERS.unicode ? "gu" : "g")
var UNIT_AFTER_NUMBER = new RegExp("\\d\\s*(?:" + LETTERS.source + "|[°$€£¥])", LETTERS.unicode ? "u" : "")

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// The user's words from a catalog value ("en dans"), lower case.
function wordList(value) {
  return String(value || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
}

// The expression for qalc, or "" when the query does not read as a
// calculation: it needs a digit and an operator or a unit, and every word must
// be a unit after a number or after "to", a function before "(", or a keyword.
// "abc + 2", a lone number and a date stay out. words: {to, of}, the user's
// language's words for a conversion ("en") and a percentage ("de").
function prepare(query, words) {
  var q = String(query || "").trim()
  if (q === "" || q.charAt(0) === "!" || q.indexOf("://") >= 0) return ""
  if (!/\d/.test(q)) return ""
  if (/^[\d\s.,]+$/.test(q)) return ""
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(q)) return ""
  // Quotes only serve text arguments (file names, command lines).
  if (/["'`‘’“”]/.test(q)) return ""

  var toWords = ENGLISH.to.concat(wordList(words && words.to))
  var ofWords = ENGLISH.of.concat(wordList(words && words.of))

  // Arrows, then "15 % de 240" as qalc reads it (240 * 15%), then the user's
  // word for "to" (qalc would read French "en" as a prefix).
  q = q.replace(/\s*(->|→|=>)\s*/g, " to ")
  var percent = new RegExp("^(\\d[\\d.,]*)\\s*%\\s*(?:" + ofWords.map(escapeRegExp).join("|") + ")\\s*(.+)$", "i").exec(q)
  if (percent) q = percent[2] + " * " + percent[1] + "%"
  for (var t = 0; t < toWords.length; t++) {
    if (ENGLISH.to.indexOf(toWords[t]) >= 0) continue
    q = q.replace(new RegExp("\\s+" + escapeRegExp(toWords[t]) + "\\s+", "gi"), " to ")
  }

  WORDS.lastIndex = 0
  var match
  var previousWord = ""
  var lastEnd = 0
  while ((match = WORDS.exec(q)) !== null) {
    var word = match[0]
    var lower = word.toLowerCase()
    if (UNSAFE[lower]) return ""
    var before = q.slice(lastEnd, match.index).replace(/\s+$/, "")
    var beforeChar = before.charAt(before.length - 1)
    var gap = q.slice(lastEnd, match.index)
    var after = q.slice(match.index + word.length).replace(/^\s+/, "")
    var ok = KEYWORDS[lower]
      || /[\d)°/*^]/.test(beforeChar)
      || after.charAt(0) === "("
      || (TARGETS[previousWord] && /^\s*$/.test(gap.replace(/[°$€£¥]/g, "")))
    if (!ok) return ""
    previousWord = lower
    lastEnd = match.index + word.length
  }
  if (!/[+\-*/×÷^%()]/.test(q) && !UNIT_AFTER_NUMBER.test(q)) return ""
  return q
}

// Currencies as qalc writes them: a three-letter code or a symbol.
var CURRENCY = /^\s*([A-Z]{3}|[$€£¥₿]|BTC)\s*$/

// The result rounded for display: 2 decimals for a currency, at most 4
// otherwise (trailing zeros dropped), 4 significant digits for a small amount. Anything other than a number with an
// optional unit is left as is. The decimal mark qalc used is kept.
function round(result) {
  var m = /^(-?)(\d+)(?:([.,])(\d+))?(\s.*|[$€£¥]|)$/.exec(result)
  if (!m || !m[4]) return result
  var mark = m[3]
  var unit = m[5]
  var value = parseFloat(m[1] + m[2] + "." + m[4])
  var money = CURRENCY.test(unit)
  // Four significant digits for a small amount (below a cent, or below 1 for
  // anything else), so it is not rounded away.
  var small = Math.abs(value) < (money ? 0.01 : 1)
  var text = small ? String(parseFloat(value.toPrecision(4)))
    : money ? value.toFixed(2) : String(parseFloat(value.toFixed(4)))
  return text.replace(".", mark) + unit
}

// qalc's output as {result, detail}, or null for an error or a warning.
// "100 USD ≈ 142,4871 CAD" gives result "142,49 CAD" and the whole line as
// detail.
function parse(output) {
  var lines = String(output || "").split("\n").map(function(l) { return l.trim() })
    .filter(function(l) { return l !== "" })
  if (lines.length === 0) return null
  for (var i = 0; i < lines.length; i++)
    if (/^(erreur|error|avertissement|warning)\b/i.test(lines[i])) return null
  var line = lines[lines.length - 1]
  var at = Math.max(line.lastIndexOf(" = "), line.lastIndexOf(" ≈ "))
  if (at < 0) return null
  var result = line.slice(at + 3).trim()
  var left = line.slice(0, at).trim()
  if (result === "" || result === left) return null
  return { result: round(result), detail: line, approximate: line.charAt(at + 1) === "≈" }
}

// Plain arithmetic (+ - * / × ÷ ^ %, parentheses) without qalc. Returns a
// number, or null when the query is anything else. A comma reads as a decimal
// point.
function basic(query) {
  var q = String(query || "").trim()
  if (!/^[\d\s.,+\-*/×÷()^%]+$/.test(q) || !/[+\-*/×÷^%]/.test(q)) return null
  var src = q.replace(/,/g, ".").replace(/×/g, "*").replace(/÷/g, "/").replace(/\s+/g, "")
  var pos = 0

  function peek() { return src.charAt(pos) }
  function number() {
    var m = /^\d*\.?\d+(?:e[+-]?\d+)?/i.exec(src.slice(pos))
    if (!m) throw "number"
    pos += m[0].length
    return parseFloat(m[0])
  }
  function factor() {
    if (peek() === "-") { pos++; return -factor() }
    if (peek() === "+") { pos++; return factor() }
    var v
    if (peek() === "(") {
      pos++
      v = sum()
      if (peek() !== ")") throw "paren"
      pos++
    } else {
      v = number()
    }
    if (peek() === "%") { pos++; v = v / 100 }
    if (peek() === "^") { pos++; v = Math.pow(v, factor()) }
    return v
  }
  function product() {
    var v = factor()
    while (peek() === "*" || peek() === "/") {
      var op = src.charAt(pos++)
      var w = factor()
      v = op === "*" ? v * w : v / w
    }
    return v
  }
  function sum() {
    var v = product()
    while (peek() === "+" || peek() === "-") {
      var op = src.charAt(pos++)
      var w = product()
      v = op === "+" ? v + w : v - w
    }
    return v
  }

  try {
    var value = sum()
    if (pos !== src.length || !isFinite(value)) return null
    return value
  } catch (e) {
    return null
  }
}

// A number for display: at most 10 significant digits, the given decimal mark.
function format(value, decimalMark) {
  var text = String(parseFloat(value.toPrecision(10)))
  return decimalMark && decimalMark !== "." ? text.replace(".", decimalMark) : text
}

// Without qalc: the plain arithmetic of a query that reads as a calculation
// (prepared first, so "15 % de 240" works and a date stays out), or null.
function fallback(query, words) {
  var expression = prepare(query, words)
  return expression === "" ? null : basic(expression)
}
