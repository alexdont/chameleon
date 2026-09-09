import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// The settings card: rotation schedule presets, the theme-match opt-in,
// pause, and manual controls. All state lives in the service; the card
// reads it reactively and mutates through service calls.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)

  function open(payloadJson) {
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.alexdont.chameleon")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io-github-alexdont-chameleon"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: content.height + card.contentTopInset + card.contentBottomInset
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: root.dismiss()
        Keys.onPressed: function(event) {
          if (!root.service) return
          if (event.key === Qt.Key_R) { root.service.rotateNow(); event.accepted = true }
          else if (event.key === Qt.Key_P) { root.service.setPaused(!root.service.paused); event.accepted = true }
          else if (event.key === Qt.Key_W) { root.dismiss(); root.service.openPicker(); event.accepted = true }
        }

        Column {
          id: content
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: card.contentTopInset
          anchors.leftMargin: card.contentLeftInset
          anchors.rightMargin: card.contentRightInset
          spacing: Style.spacing.md

          // ---- Header: title + live countdown ----
          Item {
            width: parent.width
            height: headerTitle.implicitHeight

            Text {
              id: headerTitle
              anchors.left: parent.left
              text: "Chameleon"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.service ? root.service.dueLabel() : ""
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.65
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---- Schedule ----
          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Change wallpaper every"
              color: root.selectedText
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [
                  { mins: 15, label: "15m" },
                  { mins: 30, label: "30m" },
                  { mins: 60, label: "1h" },
                  { mins: 180, label: "3h" },
                  { mins: 360, label: "6h" },
                  { mins: 720, label: "12h" },
                  { mins: 1440, label: "1 day" }
                ]

                Rectangle {
                  required property var modelData
                  readonly property bool active: root.service && root.service.intervalMinutes === modelData.mins
                  width: presetText.implicitWidth + Style.spacing.md * 2
                  height: Style.space(28)
                  radius: root.cornerRadius / 2
                  color: (presetHover.containsMouse || active) ? root.selectedBackground : "transparent"
                  border.width: 1
                  border.color: root.border
                  opacity: active ? 1 : 0.65

                  Text {
                    id: presetText
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: root.selectedText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: presetHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service) root.service.setInterval(parent.modelData.mins)
                  }
                }
              }
            }
          }

          // ---- Theme match ----
          Column {
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              height: matchLabel.implicitHeight + Style.space(6)

              Text {
                id: matchLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Match theme to wallpaper"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ToggleSwitch {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.service ? root.service.themeMatch : false
                busy: root.service ? root.service.busy : false
                onToggled: if (root.service) root.service.setThemeMatch(!root.service.themeMatch)
              }
            }

            Text {
              width: parent.width
              text: "Generates a “chameleon” theme from each new wallpaper's colors and applies it system-wide — bar, terminals, browser, editors. Off: wallpapers rotate within the current theme, which already matches."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(6)
              visible: !!root.service && root.service.themeMatch

              Repeater {
                model: [
                  { pref: "auto", label: "Auto" },
                  { pref: "dark", label: "Dark" },
                  { pref: "light", label: "Light" }
                ]

                Rectangle {
                  required property var modelData
                  readonly property bool active: root.service && root.service.modePref === modelData.pref
                  width: modeText.implicitWidth + Style.spacing.md * 2
                  height: Style.space(28)
                  radius: root.cornerRadius / 2
                  color: (modeHover.containsMouse || active) ? root.selectedBackground : "transparent"
                  border.width: 1
                  border.color: root.border
                  opacity: active ? 1 : 0.65

                  Text {
                    id: modeText
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: root.selectedText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: modeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service) root.service.setModePref(parent.modelData.pref)
                  }
                }
              }
            }
          }

          // ---- Pause ----
          Item {
            width: parent.width
            height: pauseLabel.implicitHeight + Style.space(6)

            Text {
              id: pauseLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Pause rotation"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.service ? root.service.paused : false
              onToggled: if (root.service) root.service.setPaused(!root.service.paused)
            }
          }

          // ---- Actions ----
          Row {
            spacing: Style.space(6)

            Repeater {
              model: [
                { label: "Choose wallpaper…", act: "pick" },
                { label: "Rotate now", act: "rotate" },
                { label: "Open gallery folder", act: "gallery" }
              ]

              Rectangle {
                required property var modelData
                width: actText.implicitWidth + Style.spacing.md * 2
                height: Style.space(28)
                radius: root.cornerRadius / 2
                color: actHover.containsMouse ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border
                opacity: 0.85

                Text {
                  id: actText
                  anchors.centerIn: parent
                  text: parent.modelData.label
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: actHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (!root.service) return
                    if (parent.modelData.act === "rotate") root.service.rotateNow()
                    else if (parent.modelData.act === "pick") { root.dismiss(); root.service.openPicker() }
                    else root.service.openGallery()
                  }
                }
              }
            }
          }

          Text {
            visible: !!root.service && root.service.lastError !== ""
            width: parent.width
            text: root.service ? root.service.lastError : ""
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "Drop images into ~/.config/omarchy/chameleon and those become the rotation. When it's empty, Chameleon rotates the current theme's backgrounds — or, with theme-match on, every background from every saved theme. Keys: W choose · R rotate · P pause · Esc close"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
