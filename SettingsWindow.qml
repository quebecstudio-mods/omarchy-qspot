import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "Web.js" as Web

// qSpot's settings, in a window of their own, drawn with Omarchy's controls
// like qDock's and qCenter's: the sections on the left (Appearance, Sources,
// Web, Calculations, About), the section's settings on the right. Esc or a
// click outside closes it. Everything is written to qSpot's entry in
// shell.json.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var service: null
  property bool opened: false
  property string section: "appearance"

  readonly property var sections: [
    { id: "appearance", label: strings.t("settings.appearance"), glyph: "\u{f03d8}" },
    { id: "sources", label: strings.t("settings.sources"), glyph: "\u{f0349}" },
    { id: "web", label: strings.t("settings.web"), glyph: "\u{f059f}" },
    { id: "calc", label: strings.t("settings.calc"), glyph: "\u{f00ec}" },
    { id: "about", label: strings.t("settings.about"), glyph: "\u{f02fd}" }
  ]

  readonly property var settings: service ? service.settings : ({})
  readonly property int cardRadius: Style.cornerRadius
  readonly property color foreground: Commons.Color.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property var manifest: service && service.manifest ? service.manifest : ({})

  function open(name) {
    root.section = name && sections.some(function(s) { return s.id === name }) ? name : sections[0].id
    root.opened = true
  }
  function close() { root.opened = false }
  function toggle(name) {
    if (root.opened && (!name || name === root.section)) root.close()
    else root.open(name)
  }
  onOpenedChanged: if (!opened) { root.resetForms(); root.forgotten = false }
  property bool forgotten: false

  function set(key, value, defaultValue) { root.service.setSetting(key, value, defaultValue) }

  // ---- Appearance ----
  // With qDock installed, qSpot follows its style until one is chosen here.
  readonly property bool hasDock: !!(service && service.dockSettings)
  readonly property var styleOptions: (hasDock ? [{ value: "", label: strings.t("settings.styleDock") }] : []).concat([
    { value: "omarchy", label: strings.t("settings.styleOmarchy") },
    { value: "cupertino", label: strings.t("settings.styleCupertino") },
    { value: "redmond", label: strings.t("settings.styleRedmond") },
    { value: "plasma", label: strings.t("settings.stylePlasma") }
  ])
  readonly property string styleValue: {
    var s = settings.style === "mac" ? "cupertino" : String(settings.style || "")
    if (s === "" && !hasDock) return service ? service.styleName : "cupertino"
    return s
  }

  // ---- Sources ----
  readonly property var sources: [
    { key: "apps", label: strings.t("section.apps"), help: strings.t("settings.appsHelp") },
    { key: "windows", label: strings.t("section.windows"), help: strings.t("settings.windowsHelp") },
    { key: "files", label: strings.t("section.files"), help: strings.t("settings.filesHelp") },
    { key: "recentFiles", label: strings.t("settings.recentFiles"), help: strings.t("settings.recentFilesHelp") },
    { key: "calculations", label: strings.t("section.calc"), help: strings.t("settings.calculationsHelp") },
    { key: "web", label: strings.t("section.web"), help: strings.t("settings.webSourceHelp") }
  ]

  // ---- Web ----
  readonly property var engineOptions: {
    var out = []
    for (var key in Web.ENGINES) out.push({ value: key, label: Web.ENGINES[key].name })
    return out
  }
  readonly property string engineValue: {
    var v = String(settings.searchEngine || "").toLowerCase()
    return Web.ENGINES[v] ? v : (v === "" ? "duckduckgo" : "")
  }

  readonly property var shortcuts: settings.webShortcuts && typeof settings.webShortcuts === "object" && !Array.isArray(settings.webShortcuts)
    ? settings.webShortcuts : ({})
  readonly property var shortcutKeys: Object.keys(shortcuts).sort()

  readonly property string keyToAdd: /^[a-z0-9][a-z0-9._-]*$/i.test(shortcutKey.text.trim()) ? shortcutKey.text.trim().toLowerCase() : ""
  readonly property string urlToAdd: /^https?:\/\/[^\s]+$/i.test(shortcutUrl.text.trim()) ? shortcutUrl.text.trim() : ""

  function addShortcut() {
    if (!root.keyToAdd || !root.urlToAdd) return
    var next = Object.assign({}, root.shortcuts)
    var name = shortcutName.text.trim()
    next[root.keyToAdd] = name ? { name: name, url: root.urlToAdd } : root.urlToAdd
    root.set("webShortcuts", next, {})
    root.resetForms()
  }

  function removeShortcut(key) {
    var next = Object.assign({}, root.shortcuts)
    delete next[key]
    root.set("webShortcuts", next, {})
  }

  function shortcutLabel(key) {
    var found = Web.lookup(key, root.shortcuts, null)
    return found ? found.name : key
  }

  function shortcutUrlOf(key) {
    var own = root.shortcuts[key]
    return typeof own === "string" ? own : String(own && own.url || "")
  }

  function resetForms() {
    shortcutKey.text = ""
    shortcutName.text = ""
    shortcutUrl.text = ""
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qspot-settings"

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Math.min(Style.space(720), keyCatcher.width - Style.space(32))
        height: Math.min(Style.space(540), keyCatcher.height - Style.space(32))
        radius: root.cardRadius
        color: Util.alpha(Commons.Color.popups.background, 1)
        borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
        padding: Style.spacing.md

        // Swallow clicks so only the scrim outside the card closes it.
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

        Column {
          id: sidebar
          x: card.contentLeftInset
          y: card.contentTopInset
          width: Style.space(180)
          height: card.height - card.contentTopInset - card.contentBottomInset
          spacing: Style.spacing.xs

          Row {
            spacing: Style.spacing.sm
            leftPadding: Style.spacing.controlPaddingX
            bottomPadding: Style.spacing.md
            topPadding: Style.spacing.xs

            Logo { size: Style.space(28); anchors.verticalCenter: parent.verticalCenter }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.manifest.name || "qSpot"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }

          Repeater {
            model: root.sections
            delegate: Rectangle {
              id: navRow
              required property var modelData
              readonly property bool current: root.section === modelData.id

              width: sidebar.width
              height: Style.spacing.popupRowHeight
              radius: Math.min(height / 2, root.cardRadius)
              color: current ? Commons.Color.menu.selectedBackground : (navMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: navGlyph
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.controlPaddingX
                width: Style.space(20)
                textFormat: Text.PlainText
                text: navRow.modelData.glyph
                color: navRow.current ? Commons.Color.accent : root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: navGlyph.right
                anchors.leftMargin: Style.spacing.sm
                textFormat: Text.PlainText
                text: navRow.modelData.label
                color: navRow.current ? Commons.Color.menu.selectedText : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: navRow.current
              }

              MouseArea {
                id: navMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.section = navRow.modelData.id
              }
            }
          }
        }

        // What the window leaves out is in shell.json: a quiet link to it in
        // the bottom left corner.
        Item {
          anchors.left: sidebar.left
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset + Style.spacing.xs
          width: editRow.implicitWidth
          height: editRow.implicitHeight

          readonly property color tint: editMouse.containsMouse ? root.foreground : Util.alpha(root.foreground, 0.4)

          Row {
            id: editRow
            spacing: Style.spacing.xs

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "shell.json"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.underline: editMouse.containsMouse
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "\u{f03cc}"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: editMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.close(); if (root.service) root.service.editSettings() }
          }
        }

        Button {
          visible: root.section === "about" && !!root.manifest.homepage
          anchors.right: parent.right
          anchors.rightMargin: card.contentRightInset
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset
          text: strings.t("about.homepage")
          iconText: "\u{f02a4}"
          bordered: true
          foreground: root.foreground
          onClicked: { root.close(); Util.execArgv(["xdg-open", root.manifest.homepage]) }
        }

        Rectangle {
          id: divider
          x: sidebar.x + sidebar.width + Style.spacing.md
          y: card.contentTopInset
          width: 1
          height: sidebar.height
          color: Util.alpha(root.foreground, 0.12)
        }

        Flickable {
          id: pane
          x: divider.x + divider.width + Style.spacing.lg
          y: card.contentTopInset
          width: card.width - x - card.contentRightInset - Style.spacing.sm
          height: sidebar.height
          contentWidth: width
          contentHeight: page.implicitHeight
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Connections {
            target: root
            function onSectionChanged() { pane.contentY = 0 }
          }

          Column {
            id: page
            width: pane.width
            spacing: Style.spacing.xl
            topPadding: Style.spacing.xs
            bottomPadding: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: {
                for (var i = 0; i < root.sections.length; i++)
                  if (root.sections[i].id === root.section) return root.sections[i].label
                return ""
              }
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            // ---- Appearance ----
            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.style")
              description: strings.t(root.hasDock ? "settings.styleHelpDock" : "settings.styleHelp")
              ButtonGroup {
                options: root.styleOptions
                value: root.styleValue
                foreground: root.foreground
                onChanged: v => root.set("style", v === "" ? null : v, null)
              }
            }

            Toggle {
              visible: root.section === "appearance"
              width: page.width
              label: strings.t("settings.scrim")
              description: strings.t("settings.scrimHelp")
              foreground: root.foreground
              checked: root.service.scrim
              onClicked: root.set("scrim", !root.service.scrim, root.service.look.scrim)
            }

            // ---- Sources ----
            Repeater {
              model: root.sources
              Toggle {
                required property var modelData
                visible: root.section === "sources"
                width: page.width
                label: modelData.label
                description: modelData.help
                foreground: root.foreground
                checked: root.settings[modelData.key] !== false
                onClicked: root.set(modelData.key, root.settings[modelData.key] === false, true)
              }
            }

            Toggle {
              visible: root.section === "sources"
              width: page.width
              label: strings.t("settings.learn")
              description: strings.t("settings.learnHelp")
              foreground: root.foreground
              checked: root.settings.learn !== false
              onClicked: root.set("learn", root.settings.learn === false, true)
            }

            Button {
              visible: root.section === "sources"
              height: visible ? implicitHeight : 0
              text: root.forgotten ? strings.t("settings.forgotten") : strings.t("settings.forget")
              iconText: "\u{f0a79}"
              bordered: true
              enabled: !root.forgotten
              foreground: root.foreground
              onClicked: { root.service.forgetChoices(); root.forgotten = true }
            }

            // ---- Web ----
            Setting {
              visible: root.section === "web"
              label: strings.t("settings.engine")
              description: root.engineValue === ""
                ? strings.t("settings.engineCustom").arg(String(root.settings.searchEngine || ""))
                : strings.t("settings.engineHelp")
              Dropdown {
                width: Style.space(220)
                showLabel: false
                options: root.engineOptions
                value: root.engineValue
                foreground: root.foreground
                onChanged: v => root.set("searchEngine", v, "duckduckgo")
              }
            }

            Setting {
              visible: root.section === "web"
              label: strings.t("settings.shortcuts")
              description: strings.t("settings.shortcutsHelp")

              Column {
                width: parent.width
                spacing: Style.spacing.sm

                Repeater {
                  model: root.shortcutKeys

                  ListRow {
                    required property string modelData
                    width: parent.width
                    title: "!" + modelData + " · " + root.shortcutLabel(modelData)
                    detail: root.shortcutUrlOf(modelData)
                    onRemove: root.removeShortcut(modelData)
                  }
                }

                Row {
                  spacing: Style.spacing.sm

                  TextField {
                    id: shortcutKey
                    width: Style.space(70)
                    foreground: root.foreground
                    placeholderText: "w"
                  }

                  TextField {
                    id: shortcutName
                    width: Style.space(150)
                    foreground: root.foreground
                    placeholderText: strings.t("settings.shortcutName")
                  }
                }

                TextField {
                  id: shortcutUrl
                  width: Math.min(parent.width, Style.space(380))
                  foreground: root.foreground
                  placeholderText: "https://en.wikipedia.org/w/index.php?search=%s"
                  onAccepted: root.addShortcut()
                }

                Text {
                  visible: shortcutUrl.text.trim() !== "" && !root.urlToAdd
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: strings.t("settings.shortcutUrlBad")
                  color: Commons.Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Button {
                  text: strings.t("settings.add")
                  bordered: true
                  enabled: !!root.keyToAdd && !!root.urlToAdd
                  opacity: enabled ? 1 : 0.4
                  foreground: root.foreground
                  onClicked: root.addShortcut()
                }
              }
            }

            Toggle {
              visible: root.section === "web"
              width: page.width
              label: strings.t("settings.bangUpdates")
              description: strings.t("settings.bangUpdatesHelp")
              foreground: root.foreground
              checked: root.settings.bangUpdates !== false
              onClicked: root.set("bangUpdates", root.settings.bangUpdates === false, true)
            }

            // ---- Calculations ----
            Setting {
              visible: root.section === "calc"
              label: "Qalculate"
              description: strings.t(root.service && root.service.hasQalc ? "settings.qalcThere" : "settings.qalcMissing")
              Button {
                visible: !(root.service && root.service.hasQalc)
                height: visible ? implicitHeight : 0
                text: strings.t("settings.qalcInstall")
                iconText: "\u{f01da}"
                bordered: true
                foreground: root.foreground
                onClicked: {
                  root.close()
                  Util.execArgv(["omarchy-launch-floating-terminal-with-presentation", "omarchy pkg add libqalculate"])
                }
              }
            }

            Toggle {
              visible: root.section === "calc"
              width: page.width
              label: strings.t("settings.currencyUpdates")
              description: strings.t("settings.currencyUpdatesHelp")
              foreground: root.foreground
              checked: root.settings.currencyUpdates !== false
              onClicked: root.set("currencyUpdates", root.settings.currencyUpdates === false, true)
            }

            // ---- About ----
            Row {
              visible: root.section === "about"
              width: page.width
              spacing: Style.spacing.lg

              Logo { id: aboutLogo; size: Style.space(80) }

              Column {
                anchors.verticalCenter: aboutLogo.verticalCenter
                width: page.width - aboutLogo.width - Style.spacing.lg
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: root.manifest.name || "qSpot"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Math.round(Style.font.heading * 1.3)
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.version").arg(root.manifest.version || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.credits").arg(root.manifest.author || "").arg(root.manifest.license || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              visible: root.section === "about"
              width: page.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: strings.t("about.description")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }

  // The owl, once qSpot has one; until then a magnifier in the accent.
  component Logo: Item {
    property int size: Style.space(28)
    width: size
    height: size

    Image {
      id: logoImage
      anchors.fill: parent
      source: Qt.resolvedUrl("assets/logo.png")
      sourceSize: Qt.size(parent.width * 2, parent.height * 2)
      fillMode: Image.PreserveAspectFit
      smooth: true
    }

    Text {
      anchors.centerIn: parent
      visible: logoImage.status !== Image.Ready
      text: "\u{f0349}"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Math.round(parent.size * 0.85)
    }
  }

  // A setting's name and an optional line of help over its control.
  component Setting: Column {
    id: setting
    property string label: ""
    property string description: ""
    default property alias control: holder.data

    width: parent ? parent.width : 0
    height: visible ? implicitHeight : 0
    spacing: Style.spacing.xs

    Text {
      visible: setting.label !== ""
      textFormat: Text.PlainText
      font.bold: true
      text: setting.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      visible: setting.description !== ""
      width: setting.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: setting.description
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Item { width: 1; height: Style.spacing.xs }

    Item {
      id: holder
      width: setting.width
      height: childrenRect.height
    }
  }

  // One saved entry: its name and a detail, and a button to remove it.
  component ListRow: Rectangle {
    id: listRow
    property string title: ""
    property string detail: ""
    signal remove()

    height: Style.spacing.popupRowHeight
    radius: Math.min(height / 2, root.cardRadius)
    color: Util.alpha(root.foreground, rowMouse.containsMouse ? 0.09 : 0.05)

    MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true }

    Text {
      id: rowTitle
      x: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width * 0.5)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: listRow.title
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.left: rowTitle.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: removeButton.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: listRow.detail
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      id: removeButton
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{f0156}"
      tooltipText: strings.t("settings.remove")
      foreground: root.foreground
      onClicked: listRow.remove()
    }
  }
}
