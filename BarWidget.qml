import QtQuick
import qs.Commons
import qs.Ui

// Left-click: pick a wallpaper from the thumbnail grid. Middle-click:
// rotate to the next one. Right-click: open settings. The glyph dims
// while rotation is paused.
BarWidget {
  id: root
  moduleName: "io.github.alexdont.chameleon"

  // Resolved lazily and re-tried: at shell startup the widget can be built
  // before the service registers, and a one-shot binding would then hold
  // null forever — leaving clicks dead until something reloaded us.
  property var svc: null

  function resolveSvc() {
    if (!svc && bar && bar.shell) svc = bar.shell.serviceFor(moduleName)
    return svc
  }

  onBarChanged: resolveSvc()
  Component.onCompleted: resolveSvc()

  Timer {
    interval: 400
    repeat: true
    running: !root.svc
    onTriggered: root.resolveSvc()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋩"
    horizontalMargin: 7.5
    opacity: root.svc && root.svc.paused ? 0.55 : 1
    tooltipText: root.svc ? ("Chameleon — " + root.svc.dueLabel()) : "Chameleon"
    onPressed: function(b) {
      var s = root.resolveSvc()
      if (!s) return
      if (b === Qt.RightButton) s.toggleOverlay()
      else if (b === Qt.MiddleButton) s.rotateNow()
      else s.openPicker()
    }
  }
}
