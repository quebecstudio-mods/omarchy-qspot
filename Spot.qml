import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Calc.js" as Calc
import "Web.js" as Web

// A Spotlight-style search: one field near the top of the focused screen, and
// the results grouped under it as you type. Enter opens the selected result,
// Escape clears the field, then closes.
//
// Sources, in the order they are listed: applications (the shell's shared
// app library, ranked as in Omarchy's menu), then files (bin/qspot-files:
// plocate's index, ranked; the recently used ones while the field is empty).
// A query that reads as a calculation or a conversion gets its result on top
// (qalc when installed, else plain arithmetic); Enter copies it. An address
// opens as a website; "!" starts a bang (the user's own shortcuts, then
// DuckDuckGo's, suggested as you type); a known bang followed by a space
// becomes a chip at the start of the field, and what follows is searched on
// its site (Backspace removes it). The last row searches the web. Nothing
// typed leaves the machine before Enter.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var shell: null
  property var manifest: null

  // Plugin settings, read from the plugin's entry in shell.json: the shell
  // hands them only to bar widgets.
  property var settings: ({})
  // qDock's entry, if qDock is installed: qSpot takes its style by default.
  property var dockSettings: null
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var id = root.manifest && root.manifest.id ? root.manifest.id : "quebecstudio.qspot"
      var found = {}
      var dock = null
      try {
        var list = JSON.parse(text()).plugins || []
        for (var i = 0; i < list.length; i++) {
          if (!list[i]) continue
          if (list[i].id === id) found = list[i]
          else if (list[i].id === "quebecstudio.qdock") dock = list[i]
        }
      } catch (e) {}
      root.settings = found
      root.dockSettings = dock
    }
  }

  // The style, as in qDock, qCenter and qExposé: qSpot's own "style" if set,
  // else qDock's (whose default is omarchy), else cupertino.
  readonly property string styleName: {
    var s = root.settings.style
    if (!s && root.dockSettings) s = root.dockSettings.style || "omarchy"
    if (s === "mac") s = "cupertino"
    return ["omarchy", "cupertino", "redmond", "plasma"].indexOf(s) >= 0 ? s : "cupertino"
  }
  // Cupertino: Spotlight, round and translucent, over the screen as it is.
  // Omarchy: the theme's menu, opaque, with its corners and border, over the
  // menu's scrim. Redmond: Windows' search, small corners, the field in a box
  // of its own and an accent mark on the selected row. Plasma: KRunner, a
  // compact strip hanging under the bar, nearly opaque, tight corners.
  readonly property var look: ({
    omarchy: { sheet: Style.cornerRadius, row: Style.cornerRadius, chip: Style.cornerRadius, alpha: 1,
               border: Commons.Color.menu.border, borderWidth: Math.max(1, Style.space(2)),
               scrim: true, top: false, compact: false, fieldBox: false, mark: false },
    cupertino: { sheet: Math.max(Style.cornerRadius, Style.space(16)), row: Math.max(Style.cornerRadius, Style.space(8)),
                 chip: -1, alpha: 0.85, border: Util.alpha(Commons.Color.menu.text, 0.14), borderWidth: 1,
                 scrim: false, top: false, compact: false, fieldBox: false, mark: false },
    redmond: { sheet: Style.space(8), row: Style.space(4), chip: Style.space(4), alpha: 0.92,
               border: Util.alpha(Commons.Color.menu.text, 0.1), borderWidth: 1,
               scrim: true, top: false, compact: false, fieldBox: true, mark: true },
    plasma: { sheet: Style.space(5), row: Style.space(3), chip: Style.space(3), alpha: 0.97,
              border: Util.alpha(Commons.Color.menu.text, 0.18), borderWidth: 1,
              scrim: false, top: true, compact: true, fieldBox: false, mark: false }
  })[styleName]

  // The shell hands its app library only to menu plugins, so qSpot loads its
  // own copy of Omarchy's, as qDock does: same ranking, hidden entries, icons
  // and launch feedback as the menu.
  readonly property var appLibrary: root.shell && root.shell.appLibrary ? root.shell.appLibrary : ownAppLibrary.item
  Loader {
    id: ownAppLibrary
    active: !(root.shell && root.shell.appLibrary)
    source: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/services/AppLibrary.qml"
  }
  readonly property int maxApps: 6

  // A catalog string with its %1, %2… filled in one pass, so a value holding
  // "%2" (a query) is not read as a placeholder.
  function fmt(key) {
    var values = Array.prototype.slice.call(arguments, 1)
    return strings.t(key).replace(/%(\d)/g, function(all, n) {
      var v = values[Number(n) - 1]
      return v === undefined ? all : String(v)
    })
  }

  property bool opened: false
  property string query: ""
  property int selectedIndex: 0
  onQueryChanged: if (root.opened) root.search()

  // Rows from each source, merged into the list by rebuild(). Files come back
  // later than apps (a helper process), for the query they were asked for.
  property var calcRows: []
  property var addressRows: []
  property var webRows: []
  property var appRows: []
  property var fileRows: []
  property var windowRows: []
  property var bangRows: []
  property string fileQuery: ""
  readonly property int maxFiles: 8
  readonly property string helper: Qt.resolvedUrl("bin/qspot-files").toString().replace(/^file:\/\//, "")
  readonly property string bangHelper: Qt.resolvedUrl("bin/qspot-bangs").toString().replace(/^file:\/\//, "")
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/qspot"

  // ---- Bangs -----------------------------------------------------------------
  // DuckDuckGo's list, kept by bin/qspot-bangs in qSpot's cache and refreshed
  // weekly when qSpot opens ("bangUpdates": false turns this off).
  property var bangTable: null
  readonly property int maxBangs: 6
  FileView {
    path: root.cacheDir + "/bangs.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.bangTable = Web.bangTable(JSON.parse(text())) } catch (e) {}
    }
  }

  // The list, then the icons of the most used bangs and of the user's own
  // shortcuts; new icons show at once.
  function updateBangs() {
    if (root.settings.bangUpdates === false || bangProc.running) return
    var own = []
    var shortcuts = root.settings.webShortcuts || {}
    for (var key in shortcuts) {
      var found = Web.lookup(key, shortcuts, null)
      if (found && found.domain) own.push(found.domain)
    }
    bangProc.command = ["sh", "-c", "nice -n 19 python3 -I \"$1\" update; shift; nice -n 19 python3 -I \"$0\" icons 300 \"$@\"",
      root.bangHelper, root.bangHelper].concat(own)
    bangProc.running = true
  }
  Process {
    id: bangProc
    stdout: StdioCollector {
      onStreamFinished: if (text.indexOf("updated") >= 0) iconsProc.running = true
    }
  }

  // The bang in the field's chip: {bang, name, url, domain, custom}, or null.
  property var chip: null
  onChipChanged: if (root.opened) root.search()

  // "!yt " (a bang qSpot knows, then a space) turns into the chip; what
  // follows stays in the field. Returns true when it did.
  function takeBang(text) {
    if (root.chip) return false
    var m = /^!(\S+)\s([\s\S]*)$/.exec(String(text))
    var found = m ? Web.lookup(m[1], root.settings.webShortcuts, root.bangTable) : null
    if (!found) return false
    root.chip = found
    field.text = m[2].replace(/^\s+/, "")
    return true
  }

  function setChip(found) {
    root.chip = found
    field.text = ""
  }

  // Sites' icons, fetched once a site has been opened from a bang (the
  // shell's own icon otherwise): domain -> true.
  property var siteIcons: ({})
  // Rows already shown take the icons that just arrived.
  onSiteIconsChanged: if (root.opened && (root.chip || root.query.trim().charAt(0) === "!")) root.search(true)
  Process {
    id: iconsProc
    running: true
    command: ["sh", "-c", "ls -1 \"$1\" 2>/dev/null", "qspot", root.cacheDir + "/icons"]
    stdout: StdioCollector {
      onStreamFinished: {
        var known = {}
        var names = text.split("\n")
        for (var i = 0; i < names.length; i++)
          if (/\.ico$/.test(names[i])) known[names[i].slice(0, -4)] = true
        root.siteIcons = known
      }
    }
  }

  function siteIcon(domain) {
    return domain && root.siteIcons[domain] ? "file://" + root.cacheDir + "/icons/" + domain + ".ico" : root.browserIcon
  }

  // ---- Open windows -----------------------------------------------------------
  // As on a Mac, an app that is already open is brought forward rather than
  // launched again (Shift+Enter opens a new window). Windows whose title
  // matches have their own section, unless their app is already listed.
  // Windows are matched to apps as qDock does: Hyprland's class, else the
  // terminal entry that gave the window its app id.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = String(appId || "")
    var flag = "--app-id=" + id
    for (var i = 0; i < root.terminalEntries.length; i++)
      if (String(root.terminalEntries[i].execString || "").split(/\s+/).indexOf(flag) >= 0) return DesktopEntries.byId(root.terminalEntries[i].id)
    if (id.indexOf("org.omarchy.") === 0) {
      var command = id.slice("org.omarchy.".length)
      for (var j = 0; j < root.terminalEntries.length; j++) {
        var program = String((root.terminalEntries[j].command || [])[0] || "")
        if (root.terminalEntries[j].runInTerminal && program.slice(program.lastIndexOf("/") + 1) === command)
          return DesktopEntries.byId(root.terminalEntries[j].id)
      }
    }
    return null
  }

  readonly property string minimizedWorkspace: "special:minimized"

  // Every app window: {address, title, key, name, icon, workspaceId, minimized, activated}.
  function openWindows() {
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      var minimized = !!workspace && String(workspace.name || "") === root.minimizedWorkspace
      var workspaceId = workspace ? workspace.id : -1
      if (workspaceId < 1 && !minimized) continue
      out.push({
        address: String(toplevels[i].address || ""),
        title: String(toplevel.title || ""),
        key: entry ? String(entry.id) : String(toplevel.appId),
        name: entry && root.appLibrary ? root.appLibrary.entryName(entry) : String(toplevel.appId),
        icon: entry && root.appLibrary ? root.appLibrary.iconSource(entry.icon) : "",
        workspaceId: workspaceId,
        minimized: minimized,
        activated: !!toplevel.activated
      })
    }
    return out
  }

  // The window to bring forward for an app: the focused one, else one on the
  // workspace in front of the user, else the first.
  function windowFor(key) {
    var windows = root.openWindows().filter(function(w) { return w.key === key })
    if (windows.length === 0) return null
    var monitor = Hyprland.focusedMonitor
    var current = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    for (var i = 0; i < windows.length; i++) if (windows[i].activated) return windows[i]
    for (var j = 0; j < windows.length; j++) if (windows[j].workspaceId === current) return windows[j]
    return windows[0]
  }

  // Windows whose title or app matches, apps already listed aside.
  function windowSearch(q, appKeys) {
    var words = q.toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
    if (words.length === 0) return []
    var rows = []
    var windows = root.openWindows()
    for (var i = 0; i < windows.length && rows.length < root.maxWindows; i++) {
      var w = windows[i]
      if (appKeys[w.key]) continue
      var text = (w.title + " " + w.name).toLowerCase()
      if (!words.every(function(word) { return text.indexOf(word) >= 0 })) continue
      rows.push({
        section: strings.t("section.windows"), kind: "window", value: w.address,
        title: w.title || w.name,
        subtitle: w.minimized ? root.fmt("window.minimized", w.name) : root.fmt("window.where", w.name, w.workspaceId),
        icon: w.icon
      })
    }
    return rows
  }
  readonly property int maxWindows: 5

  // Some apps keep to one window (Spotify): asked for another, they only wake
  // the one they have, which asks for attention without getting the focus.
  // When no new window has appeared shortly after Shift+Enter, the existing
  // one is brought forward.
  Timer {
    id: singleCheck
    property string key: ""
    property var before: []
    interval: 1500
    function watch(key) {
      singleCheck.key = key
      singleCheck.before = root.openWindows().filter(function(w) { return w.key === key }).map(function(w) { return w.address })
      singleCheck.restart()
    }
    onTriggered: {
      var known = singleCheck.before
      var now = root.openWindows().filter(function(w) { return w.key === singleCheck.key })
      if (now.some(function(w) { return known.indexOf(w.address) < 0 })) return
      var w = root.windowFor(singleCheck.key)
      if (w) root.bringForward(w.address, w.minimized)
    }
  }

  // Brings a window forward, as qDock does: a minimized one first comes back
  // to the workspace in front of the user.
  function bringForward(address, minimized) {
    if (!address) return
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var steps = []
    if (minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (workspace >= 1) steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    Util.execDetached(steps.map(function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }).join(" && "))
  }

  // ---- What the user picks ----------------------------------------------------
  // Each app or file opened is remembered under what was typed and its
  // beginnings ("f", "fo", "for"): next time, the one picked most for it,
  // lately, comes first as the top hit. A pick weighs half as much after 30
  // days. Kept in ~/.local/state/qspot/choices.json, nowhere else; "learn":
  // false turns it off.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/qspot"
  readonly property bool learning: root.settings.learn !== false
  property var choices: ({})
  readonly property int maxPrefix: 16
  readonly property int maxPrefixes: 1000
  readonly property real halfLife: 30 * 86400000

  Process {
    running: true
    command: ["mkdir", "-p", root.stateDir]
  }

  FileView {
    id: choicesFile
    path: root.stateDir + "/choices.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try { root.choices = JSON.parse(text()) || {} } catch (e) { root.choices = {} }
    }
  }

  function normalized(q) {
    return String(q || "").trim().toLowerCase().replace(/\s+/g, " ").slice(0, root.maxPrefix)
  }

  function weight(e, now) {
    return e ? e.n * Math.pow(0.5, (now - e.t) / root.halfLife) : 0
  }

  function learn(row, q) {
    if (!root.learning || (row.kind !== "app" && row.kind !== "file") || row.bang !== "") return
    var typed = root.normalized(q)
    if (typed === "") return
    var key = row.kind + ":" + row.value
    var now = Date.now()
    var all = root.choices
    for (var l = 1; l <= typed.length; l++) {
      var prefix = typed.slice(0, l)
      if (prefix.slice(-1) === " ") continue
      var picks = all[prefix] || {}
      picks[key] = { n: root.weight(picks[key], now) + 1, t: now }
      // The five strongest picks per beginning.
      var keys = Object.keys(picks).sort(function(a, b) { return root.weight(picks[b], now) - root.weight(picks[a], now) })
      for (var k = 5; k < keys.length; k++) delete picks[keys[k]]
      all[prefix] = picks
    }
    // The beginnings used least lately go first when there are too many.
    var prefixes = Object.keys(all)
    if (prefixes.length > root.maxPrefixes) {
      var latest = function(p) { var m = 0; for (var x in all[p]) m = Math.max(m, all[p][x].t); return m }
      prefixes.sort(function(a, b) { return latest(a) - latest(b) })
      for (var i = 0; i < prefixes.length - root.maxPrefixes; i++) delete all[prefixes[i]]
    }
    root.choices = all
    choicesFile.setText(JSON.stringify(all) + "\n")
  }

  function forgetChoices() {
    root.choices = {}
    choicesFile.setText("{}\n")
  }

  // The learned weight of a row for what is typed now, from the longest
  // beginning of it something was picked for: a pick made at "go" still
  // counts at "goo", as long as the row matches.
  function learned(row, q) {
    if (!root.learning || (row.kind !== "app" && row.kind !== "file")) return 0
    var typed = root.normalized(q)
    for (var l = typed.length; l > 0; l--) {
      var picks = root.choices[typed.slice(0, l)]
      if (picks) return root.weight(picks[row.kind + ":" + row.value], Date.now())
    }
    return 0
  }

  // ---- Settings window ------------------------------------------------------
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string userShellJson: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"

  // Writes one setting to shell.json; the default removes it.
  function setSetting(key, value, defaultValue) {
    var json = value === null || JSON.stringify(value) === JSON.stringify(defaultValue) ? "null" : JSON.stringify(value)
    Util.execArgv([root.pluginDir + "bin/qspot-config", key, json])
  }

  function editSettings() {
    Util.execArgv(["omarchy-launch-config-editor", root.userShellJson])
  }

  SettingsWindow {
    id: settingsWindow
    service: root
  }

  function openSettings(section) {
    root.close()
    settingsWindow.toggle(section)
  }

  ShellIpc {
    target: "quebecstudio.qspot"

    function toggle(): void { root.toggle() }
    // Opens with the field already filled, for a dock or a start menu.
    function open(text: string): void { root.open(text) }
    function close(): void { root.close() }
    function settings(): void { root.openSettings("") }
    function settingsAt(section: string): void { root.openSettings(section) }
    function about(): void { root.openSettings("about") }
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("")
  }

  function open(text) {
    settingsWindow.close()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.updateRates()
    root.refreshIndex(300)
    root.updateBangs()
    iconsProc.running = true
    root.chip = null
    root.opened = true
    root.fileRows = []
    field.text = String(text || "")
    root.query = field.text
    root.search()
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    fileTimer.stop()
    filesProc.pending = false
    calcProc.pending = false
    if (calcProc.running) calcProc.running = false
    root.chip = null
  }

  // Apps at once; files after a short pause in the typing. keepSelection:
  // the rows are only refreshed (icons, qalc found), the selection stays.
  function search(keepSelection) {
    var q = root.query.trim()
    // A bang is all there is: apps, files and calculations would only match
    // its letters. In the chip, the terms are searched on its site; while
    // the bang is being typed, the bangs it may be are suggested.
    if (root.chip || q.charAt(0) === "!") {
      root.calcRows = []
      root.addressRows = []
      root.appRows = []
      root.fileRows = []
      root.windowRows = []
      root.webRows = []
      root.bangRows = []
      fileTimer.stop()
      calcProc.pending = false
      var m = /^!(\S*)(?:\s+([\s\S]*))?$/.exec(q)
      if (root.chip) {
        root.webRows = [root.bangRow(root.chip, q)]
      } else if (m && m[2] === undefined) {
        var found = Web.suggest(m[1], root.settings.webShortcuts, root.bangTable, root.maxBangs)
        root.bangRows = found.map(function(b) { return root.bangRow(b, "") })
        if (found.length === 0 && m[1] !== "") root.webRows = [root.unknownBangRow(q, m[1])]
      } else if (m) {
        root.webRows = [root.unknownBangRow(q, m[1])]
      }
      root.rebuild(!keepSelection)
      return
    }
    root.bangRows = []
    var useWeb = root.settings.web !== false
    var site = useWeb ? Web.address(q) : null
    root.addressRows = site ? [root.webRow(root.fmt("web.open", site.label), site.url, site.url)] : []
    var web = Web.search(q, root.settings.searchEngine)
    root.webRows = q === "" || !useWeb ? [] : [root.webRow(root.fmt("web.search", q), root.fmt("web.searchDetail", web.name), web.url)]
    var apps = []
    var runningKeys = {}
    if (q !== "" && root.settings.windows !== false) {
      var open = root.openWindows()
      for (var o = 0; o < open.length; o++) runningKeys[open[o].key] = true
    }
    if (q !== "" && root.appLibrary && root.settings.apps !== false) {
      var found = root.appLibrary.sortedEntries(q)
      for (var i = 0; i < found.length && i < root.maxApps; i++) {
        var entry = found[i].entry
        var running = runningKeys[String(entry.id || "")]
        apps.push({
          section: strings.t("section.apps"),
          kind: "app",
          value: String(entry.id || ""),
          title: root.appLibrary.entryName(entry),
          subtitle: running ? strings.t("app.running") : (root.appLibrary.entrySubtext(entry) || ""),
          icon: root.appLibrary.iconSource(entry.icon)
        })
      }
    }
    root.appRows = apps
    var listed = {}
    for (var a = 0; a < apps.length; a++) listed[apps[a].value] = true
    root.windowRows = q !== "" && root.settings.windows !== false ? root.windowSearch(q, listed) : []
    root.calculate(root.settings.calculations === false ? "" : q)
    // Old file results stay until new ones arrive, unless they no longer match.
    if (q === "" || root.fileQuery === "" || q.toLowerCase().indexOf(root.fileQuery.toLowerCase()) < 0)
      root.fileRows = []
    root.rebuild(!keepSelection)
    if (q === "" ? root.settings.recentFiles !== false : root.settings.files !== false) fileTimer.restart()
    else root.fileRows = []
  }

  Timer {
    id: fileTimer
    interval: root.query.trim() === "" ? 0 : 120
    onTriggered: root.searchFiles()
  }

  // One search at a time: a query typed meanwhile waits for it to end (killed,
  // it would hand back an empty answer), then runs.
  function searchFiles() {
    if (filesProc.running) {
      filesProc.pending = true
      return
    }
    filesProc.pending = false
    if (!root.opened) return
    var q = root.query.trim()
    filesProc.asked = q
      filesProc.command = q === ""
        ? ["python3", "-I", root.helper, "recent", String(root.maxFiles)]
      : ["python3", "-I", root.helper, "search", q, String(root.maxFiles)]
    filesProc.running = true
  }

  Process {
    id: filesProc
    property string asked: ""
    property bool pending: false
    onExited: if (filesProc.pending) root.searchFiles()
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.opened || filesProc.pending || filesProc.asked !== root.query.trim()) return
        var rows = []
        try { rows = JSON.parse(text) } catch (e) { rows = [] }
        var section = filesProc.asked === "" ? strings.t("section.recent") : strings.t("section.files")
        root.fileRows = rows.map(function(r) {
          return {
            section: section,
            kind: "file",
            value: r.path,
            title: r.name,
            subtitle: r.parent,
            icon: root.fileIcon(r.name, r.dir)
          }
        })
        root.fileQuery = filesProc.asked
        root.rebuild(false)
      }
    }
  }

  // Calculations. qalc runs with qSpot's own settings (units not mixed, so
  // "5 km to mi" gives 3.1 mi; "." and "," both decimal marks), kept apart
  // from the user's own qalc settings; exchange rates are the shared ones.
  property bool hasQalc: false
  readonly property string qalcHome: Quickshell.env("HOME") + "/.local/state/qspot"
  readonly property var calcIcon: Quickshell.iconPath("accessories-calculator", true)
    || Quickshell.iconPath("applications-accessories", true)

  Process {
    running: true
    command: ["sh", "-c", "command -v qalc >/dev/null || exit 1; d=\"$1/qalculate\"; mkdir -p \"$d\"; "
      + "f=\"$d/qalc.cfg\"; [ -f \"$f\" ] || printf '[General]\\nmixed_units_conversion=0\\ndot_as_separator=0\\n' > \"$f\"; "
      // Rates are fetched by updateRates() only, never while typing.
      + "grep -q '^auto_update_exchange_rates=' \"$f\" && sed -i 's/^auto_update_exchange_rates=.*/auto_update_exchange_rates=0/' \"$f\" "
      + "|| sed -i '/^\\[General\\]/a auto_update_exchange_rates=0' \"$f\"",
      "qspot", root.qalcHome]
    onExited: function(code) { root.hasQalc = code === 0 }
  }
  // Opened before the check ended: the calculation is done again with qalc.
  onHasQalcChanged: if (root.opened) root.search(true)

  // Exchange rates older than a day are refreshed in the background, when
  // qSpot opens; the "currencyUpdates" setting turns this off.
  function updateRates() {
    if (!root.hasQalc || root.settings.currencyUpdates === false) return
    Quickshell.execDetached(["sh", "-c",
      "f=\"${XDG_DATA_HOME:-$HOME/.local/share}/qalculate/rates.json\"; "
      + "[ -n \"$(find \"$f\" -mmin -1440 2>/dev/null)\" ] || XDG_CONFIG_HOME=\"$1\" qalc -e 1 </dev/null >/dev/null 2>&1",
      "qspot", root.qalcHome])
  }

  // The user's language's words for a conversion and a percentage (see Calc.js).
  readonly property var calcWords: ({ to: strings.t("calc.to", ""), of: strings.t("calc.of", "") })


  function calculate(q) {
    var expression = Calc.prepare(q, root.calcWords)
    calcProc.pending = false
    if (expression === "") {
      root.calcRows = []
      return
    }
    if (root.hasQalc) {
      // As for files, one qalc at a time; the latest query waits its turn.
      calcProc.nextQuery = q
      calcProc.nextExpression = expression
      calcProc.pending = true
      if (!calcProc.running) root.runCalc()
      return
    }
    var value = Calc.fallback(q, root.calcWords)
    if (value !== null) {
      var shown = Calc.format(value, Qt.locale().decimalPoint)
      root.calcRows = [root.calcRow(shown, expression + " = " + shown)]
    } else {
      root.calcRows = [{
        section: strings.t("section.calc"), kind: "install", value: "",
        title: strings.t("calc.install"), subtitle: strings.t("calc.installDetail"), icon: root.calcIcon
      }]
    }
  }

  function calcRow(result, detail) {
    return { section: strings.t("section.calc"), kind: "calc", value: result, title: result, subtitle: detail, icon: root.calcIcon }
  }

  function runCalc() {
    calcProc.pending = false
    if (!root.opened) return
    calcProc.asked = calcProc.nextQuery
    calcProc.command = ["env", "XDG_CONFIG_HOME=" + root.qalcHome, "qalc", calcProc.nextExpression]
    calcProc.running = true
  }

  Process {
    id: calcProc
    property string asked: ""
    property string nextQuery: ""
    property string nextExpression: ""
    property bool pending: false
    onExited: if (calcProc.pending) root.runCalc()
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.opened || root.chip || calcProc.pending || calcProc.asked !== root.query.trim()) return
        var answer = Calc.parse(text)
        root.calcRows = answer ? [root.calcRow(answer.result, answer.detail)] : []
        root.rebuild(false)
      }
    }
  }

  // qSpot's index of the home folder (bin/qspot-files index): rebuilt in the
  // background, at low priority, when qSpot opens and it is over 5 minutes
  // old, and every 30 minutes. When a rebuild lands while qSpot is open, the
  // files are searched again, so a file saved a minute ago shows up.
  function refreshIndex(maxAge) {
    if (indexProc.running) return
    indexProc.command = ["nice", "-n", "19", "ionice", "-c", "3", "python3", "-I", root.helper, "index", String(maxAge)]
    indexProc.running = true
  }

  Process {
    id: indexProc
    stdout: StdioCollector {
      onStreamFinished: if (text.indexOf("updated") >= 0 && root.opened) fileTimer.restart()
    }
  }

  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshIndex(25 * 60)
  }

  function webRow(title, detail, url) {
    return { section: strings.t("section.web"), kind: "url", value: url, title: title, subtitle: detail, icon: root.browserIcon }
  }

  // A bang's row: its site with the terms, or, as a suggestion, the site
  // alone (Tab puts it in the chip).
  function bangRow(b, terms) {
    var url = Web.bangUrl(b, terms)
    var title = terms !== "" ? root.fmt("web.bangTerms", b.name, terms) : b.name
    var detail = b.custom ? root.fmt("web.bangOwn", b.bang)
      : root.fmt("web.bangDuck", b.bang, b.domain.replace(/^www\./, ""))
    return {
      section: terms === "" && !root.chip ? strings.t("section.bangs") : strings.t("section.web"),
      kind: "url", value: url, title: title, subtitle: detail,
      icon: root.siteIcon(b.domain), domain: b.domain, bang: b.bang
    }
  }

  function unknownBangRow(q, key) {
    return root.webRow(q, root.fmt("web.bangUnknown", key), Web.unknownBang(q))
  }

  // The default browser's icon for web rows. Omarchy's default is its own
  // omarchy-browser entry, which has no icon: omarchy-cmd-default-browser
  // names the browser behind it. Else xdg-settings, else a generic icon.
  property string browserId: ""
  readonly property var browserIcon: {
    var entry = root.browserId !== "" ? DesktopEntries.byId(root.browserId) : null
    if (entry && root.appLibrary) return root.appLibrary.iconSource(entry.icon)
    return Quickshell.iconPath("internet-web-browser", true) || Quickshell.iconPath("applications-internet", true)
  }
  Process {
    running: true
    command: ["sh", "-c", "omarchy-cmd-default-browser 2>/dev/null || xdg-settings get default-web-browser"]
    stdout: StdioCollector { onStreamFinished: root.browserId = text.trim().replace(/\.desktop$/, "") }
  }

  // A themed icon for a file, from its extension.
  function fileIcon(name, isDir) {
    var ext = String(name).toLowerCase().replace(/^.*\./, "")
    var icon = "text-x-generic"
    if (isDir) icon = "folder"
    else if (ext === "pdf") icon = "application-pdf"
    else if (["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tif", "tiff", "ico"].indexOf(ext) >= 0) icon = "image-x-generic"
    else if (["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"].indexOf(ext) >= 0) icon = "audio-x-generic"
    else if (["mp4", "mkv", "webm", "mov", "avi", "m4v"].indexOf(ext) >= 0) icon = "video-x-generic"
    else if (["zip", "tar", "gz", "xz", "zst", "bz2", "7z", "rar"].indexOf(ext) >= 0) icon = "package-x-generic"
    else if (["doc", "docx", "odt", "rtf"].indexOf(ext) >= 0) icon = "x-office-document"
    else if (["xls", "xlsx", "ods", "csv"].indexOf(ext) >= 0) icon = "x-office-spreadsheet"
    else if (["ppt", "pptx", "odp", "key"].indexOf(ext) >= 0) icon = "x-office-presentation"
    else if (["html", "htm"].indexOf(ext) >= 0) icon = "text-html"
    else if (["sh", "py", "js", "ts", "php", "qml", "lua", "rs", "go", "rb", "json", "yaml", "yml", "toml", "css", "scss", "vue", "twig"].indexOf(ext) >= 0) icon = "text-x-script"
    return Quickshell.iconPath(icon, true) || Quickshell.iconPath("text-x-generic", true)
  }

  // Whether the user moved the selection since the query changed: until then
  // it stays on the first row, the top hit arriving with the files included.
  property bool userPicked: false

  // Refills the list from the sources, keeping the row the user picked when
  // it is still there (files arriving must not move it under them).
  function rebuild(resetSelection) {
    pointerGate.reset()
    if (resetSelection) root.userPicked = false
    var kept = root.userPicked && root.selectedIndex >= 0 && root.selectedIndex < results.count
      ? results.get(root.selectedIndex).value : ""
    results.clear()
    // The app or file picked most for what is typed, lately, leads as the
    // top hit; the other apps follow in the order learned, then the menu's.
    var q = root.query
    var apps = root.appRows.slice()
    var files = root.fileRows.slice()
    var best = null, bestWeight = 0.5
    var candidates = apps.concat(files)
    for (var c = 0; c < candidates.length; c++) {
      var w = root.learned(candidates[c], q)
      if (w > bestWeight) { best = candidates[c]; bestWeight = w }
    }
    var top = []
    if (best) {
      apps = apps.filter(function(r) { return r !== best })
      files = files.filter(function(r) { return r !== best })
      top = [Object.assign({}, best, { section: strings.t("section.top") })]
    }
    if (root.learning) {
      var order = apps.map(function(r, i) { return { row: r, i: i, w: root.learned(r, q) } })
      order.sort(function(a, b) { return b.w - a.w || a.i - b.i })
      apps = order.map(function(o) { return o.row })
    }
    var rows = top.concat(root.calcRows, root.bangRows, root.addressRows, apps, root.windowRows, files, root.webRows)
    var selected = rows.length > 0 ? 0 : -1
    for (var i = 0; i < rows.length; i++) {
      // Every row has every role: a ListModel takes its roles from the first.
      results.append(Object.assign({ domain: "", bang: "" }, rows[i]))
      if (kept !== "" && rows[i].value === kept) {
        selected = i
        kept = ""
      }
    }
    root.selectedIndex = selected
    if (resetSelection) list.positionViewAtBeginning()
  }

  function move(delta) {
    pointerGate.reset()
    if (results.count === 0) return
    root.userPicked = true
    root.selectedIndex = (root.selectedIndex + delta + results.count) % results.count
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectedRow() {
    return root.selectedIndex >= 0 && root.selectedIndex < results.count ? results.get(root.selectedIndex) : null
  }

  // Enter: open (an open app: bring its window forward). Ctrl+Enter: show a
  // file in its folder. Shift+Enter: a new window of an open app.
  function activate(index, reveal, newWindow) {
    if (index < 0 || index >= results.count) return
    var row = results.get(index)
    // A bang that needs terms (%s in its site, no "home"): into the chip.
    if (row.kind === "url" && row.value === "") {
      var found = row.bang !== "" && !root.chip ? Web.lookup(row.bang, root.settings.webShortcuts, root.bangTable) : null
      if (found) root.setChip(found)
      return
    }
    root.learn(row, root.query)
    root.close()
    if (row.kind === "url") {
      Quickshell.execDetached(["xdg-open", row.value])
      // The site is open: its icon for next time.
      if (row.domain !== "" && !root.siteIcons[row.domain] && root.settings.bangUpdates !== false)
        Quickshell.execDetached(["nice", "-n", "19", "python3", "-I", root.bangHelper, "icon", row.domain])
    } else if (row.kind === "calc") {
      Quickshell.execDetached(["wl-copy", row.value])
    } else if (row.kind === "install") {
      Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy pkg add libqalculate"])
    } else if (row.kind === "window") {
      var w = root.openWindows().filter(function(x) { return x.address === row.value })[0]
      if (w) root.bringForward(w.address, w.minimized)
    } else if (row.kind === "app" && root.appLibrary) {
      var running = root.settings.windows === false ? null : root.windowFor(row.value)
      if (running && !newWindow) {
        root.bringForward(running.address, running.minimized)
      } else {
        root.appLibrary.launch(row.value, row.title)
        if (running) singleCheck.watch(row.value)
      }
    } else if (row.kind === "file" && reveal) {
      // The file manager's standard D-Bus call selects the file in its
      // folder; without one, the folder opens.
      // Each segment encoded, quotes too: the URI sits in a GVariant string.
      var uri = "file://" + row.value.split("/").map(function(part) {
        return encodeURIComponent(part).replace(/[!'()*]/g, function(c) { return "%" + c.charCodeAt(0).toString(16).toUpperCase() })
      }).join("/")
      Quickshell.execDetached(["sh", "-c",
        "gdbus call --session --dest org.freedesktop.FileManager1 --object-path /org/freedesktop/FileManager1 "
        + "--method org.freedesktop.FileManager1.ShowItems \"['$1']\" '' >/dev/null 2>&1 || gio open \"$(dirname \"$2\")\"",
        "qspot", uri, row.value])
    } else if (row.kind === "file") {
      // gio honours Terminal=true entries (a text file opening in Neovim);
      // xdg-open is the fallback.
      Quickshell.execDetached(["sh", "-c", "gio open \"$1\" 2>/dev/null || xdg-open \"$1\"", "qspot", row.value])
    }
  }

  // Ctrl+C with nothing selected in the field: copy the file's path.
  function copyPath() {
    var row = root.selectedRow()
    if (!row || row.kind !== "file") return false
    Quickshell.execDetached(["wl-copy", row.value])
    root.close()
    return true
  }

  ListModel { id: results }

  // Rows rebuilt under a pointer that does not move must not take the
  // selection from the keyboard.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qspot"

    Rectangle {
      anchors.fill: parent
      color: root.look.scrim ? Commons.Color.menu.scrim : "transparent"
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: card
      readonly property int pad: Style.space(10)
      width: Math.min(Style.space(root.look.compact ? 580 : 640), panel.width - Style.gapsOut * 2)
      height: fieldRow.height + (list.count > 0 || root.query.trim() !== "" ? listBox.height + pad : 0) + pad * 2
      x: Math.round((panel.width - width) / 2)
      // Plasma hangs under a top bar; the others sit a fifth of the way down.
      y: root.look.top ? Style.bar.sizeHorizontal + Style.gapsOut : Math.round(panel.height * 0.22)
      radius: root.look.sheet
      color: Util.alpha(Commons.Color.menu.background, root.look.alpha)
      border.width: root.look.borderWidth
      border.color: root.look.border

      // Redmond: the field in a box of its own, its bottom edge in the accent.
      Rectangle {
        visible: root.look.fieldBox
        x: card.pad
        y: card.pad - Style.space(2)
        width: card.width - card.pad * 2
        height: fieldRow.height + Style.space(4)
        radius: root.look.row
        color: Util.alpha(Commons.Color.menu.text, 0.06)
        border.width: 1
        border.color: Util.alpha(Commons.Color.menu.text, 0.12)
        Rectangle {
          anchors.bottom: parent.bottom
          x: parent.radius
          width: parent.width - parent.radius * 2
          height: Math.max(1, Style.space(2))
          color: Commons.Color.accent
        }
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Row {
        id: fieldRow
        x: card.pad + Style.space(6)
        y: card.pad
        width: card.width - x * 2
        height: Style.space(root.look.compact ? 38 : 48)
        spacing: Style.space(12)

        Text {
          id: glyph
          anchors.verticalCenter: parent.verticalCenter
          text: "󰍉"
          color: Commons.Color.menu.text
          opacity: 0.7
          font.family: Style.font.menuFamily
          font.pixelSize: root.look.compact ? Style.font.heading : Style.font.display
        }

        // The bang's chip: its site's icon, when qSpot has it, and name.
        Rectangle {
          id: chipBox
          visible: !!root.chip
          readonly property bool hasIcon: !!root.chip && !!root.siteIcons[root.chip.domain]
          anchors.verticalCenter: parent.verticalCenter
          width: visible ? chipContent.implicitWidth + height * 0.9 : 0
          height: Math.round((root.look.compact ? Style.font.heading : Style.font.display) * 1.35)
          radius: root.look.chip < 0 ? height / 2 : Math.min(root.look.chip, height / 2)
          color: Commons.Color.menu.selectedBackground

          Row {
            id: chipContent
            anchors.centerIn: parent
            spacing: Style.space(6)

            Image {
              visible: chipBox.hasIcon
              anchors.verticalCenter: parent.verticalCenter
              width: Math.round(chipBox.height * 0.6)
              height: width
              sourceSize: Qt.size(width * 2, height * 2)
              source: chipBox.hasIcon ? root.siteIcon(root.chip.domain) : ""
              fillMode: Image.PreserveAspectFit
            }

            Text {
              id: chipText
              anchors.verticalCenter: parent.verticalCenter
              text: root.chip ? root.chip.name : ""
              textFormat: Text.PlainText
              color: Commons.Color.menu.selectedText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.chip = null; field.forceActiveFocus() }
          }
        }

        TextInput {
          id: field
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - glyph.width - gear.width - parent.spacing * 2 - (chipBox.visible ? chipBox.width + parent.spacing : 0)
          clip: true
          color: Commons.Color.menu.text
          selectionColor: Commons.Color.menu.selectedBackground
          selectedTextColor: Commons.Color.menu.selectedText
          font.family: Style.font.menuFamily
          font.pixelSize: root.look.compact ? Style.font.heading : Style.font.display
          onTextChanged: if (!root.takeBang(text)) root.query = text

          Text {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            visible: field.text === ""
            text: root.chip ? root.fmt("field.bangPlaceholder", root.chip.name) : strings.t("field.placeholder")
            color: Commons.Color.menu.text
            opacity: 0.45
            font: field.font
          }

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (field.text !== "" || root.chip) { root.chip = null; field.text = "" }
              else root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Backspace && root.chip && field.cursorPosition === 0 && field.selectedText === "") {
              root.chip = null
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              // Tab takes the selected bang into the chip; the field keeps
              // the focus either way.
              var row = root.chip ? null : root.selectedRow()
              var found = row && row.bang !== "" ? Web.lookup(row.bang, root.settings.webShortcuts, root.bangTable) : null
              if (found) root.setChip(found)
              event.accepted = true
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier)) {
              root.move(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier)) {
              root.move(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.activate(root.selectedIndex, (event.modifiers & Qt.ControlModifier) !== 0, (event.modifiers & Qt.ShiftModifier) !== 0)
              event.accepted = true
            } else if (event.key === Qt.Key_C && event.modifiers === Qt.ControlModifier && field.selectedText === "") {
              event.accepted = root.copyPath()
            }
          }
        }

        // The settings, quietly at the end of the field.
        Text {
          id: gear
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{f0493}"
          color: Commons.Color.menu.text
          opacity: gearMouse.containsMouse ? 0.9 : 0.35
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title

          MouseArea {
            id: gearMouse
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openSettings("")
          }
        }
      }

      Item {
        id: listBox
        visible: card.height > fieldRow.height + card.pad * 2
        x: card.pad
        y: fieldRow.y + fieldRow.height + card.pad
        width: card.width - card.pad * 2
        readonly property int rowH: Style.space(root.look.compact ? 38 : 44)
        readonly property int headerH: Math.round(Style.font.caption * 2.2)
        height: list.count > 0 ? Math.min(list.contentHeight, Style.space(460)) : rowH

        Rectangle {
          anchors.top: parent.top
          width: parent.width
          height: 1
          y: -Math.round(card.pad / 2)
          color: Util.alpha(Commons.Color.muted, 0.3)
        }

        ListView {
          id: list
          anchors.fill: parent
          clip: true
          model: results
          boundsBehavior: Flickable.StopAtBounds
          section.property: "section"
          section.delegate: Text {
            required property string section
            width: list.width
            height: listBox.headerH
            leftPadding: Style.space(10)
            verticalAlignment: Text.AlignBottom
            bottomPadding: Style.space(4)
            text: section
            color: Commons.Color.menu.text
            opacity: 0.55
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          delegate: Rectangle {
            id: row
            required property int index
            required property string title
            required property string subtitle
            required property string icon
            readonly property bool selected: index === root.selectedIndex

            width: list.width
            height: listBox.rowH
            radius: root.look.row
            color: selected ? Commons.Color.menu.selectedBackground : "transparent"

            // Redmond: the selected row's accent mark.
            Rectangle {
              visible: root.look.mark && row.selected
              x: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(3)
              height: Math.round(parent.height * 0.45)
              radius: width / 2
              color: Commons.Color.accent
            }

            Image {
              id: rowIcon
              x: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              height: width
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: row.icon
              asynchronous: true
              fillMode: Image.PreserveAspectFit
            }

            Column {
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                text: row.title
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: row.selected ? Commons.Color.menu.selectedText : Commons.Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.title
              }
              Text {
                width: parent.width
                visible: row.subtitle !== ""
                text: row.subtitle
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: row.selected ? Commons.Color.menu.selectedText : Commons.Color.menu.text
                opacity: 0.6
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: function(mouse) {
                if (pointerGate.moved(row, mouse)) {
                  root.userPicked = true
                  root.selectedIndex = row.index
                }
              }
              onClicked: root.activate(row.index, false)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: list.count === 0 && !filesProc.running
          text: root.fmt("results.none", root.query.trim())
          textFormat: Text.PlainText
          color: Commons.Color.menu.text
          opacity: 0.6
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
