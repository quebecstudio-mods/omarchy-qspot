import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The magnifier for the bar: a click opens or closes qSpot; a right click
// opens its settings.
BarWidget {
  id: root
  moduleName: "quebecstudio.qspot"
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍉"
    tooltipText: strings.t("bar.tooltip")
    onPressed: function(button) {
      if (root.bar) root.bar.run("omarchy-shell -q quebecstudio.qspot " + (button === Qt.RightButton ? "settings" : "toggle"))
    }
  }
}
