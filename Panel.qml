import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Copy Tracker. Watches the Wayland clipboard in the background and logs
// every copy action as a row in a SQLite database (track.sh owns the
// schema/queries). The bar icon shows the running entry count; clicking it
// opens a scrollable history you can re-copy from or delete individual
// entries out of.
Panel {
  id: root
  moduleName: "copytracker"
  ipcTarget: "copytracker"

  property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/copytracker/track.sh"
  property var entries: []
  property bool clearConfirmOpen: false
  property string searchQuery: ""
  property int selectedIndex: -1

  readonly property string icon: "" // nf-cod-copy

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    listProc.running = false
    var cmd = ["bash", root.scriptPath, "list", "300"]
    if (root.searchQuery.length > 0) cmd.push(root.searchQuery)
    listProc.command = cmd
    listProc.running = true
  }

  function copyEntry(id) {
    Quickshell.execDetached(["bash", root.scriptPath, "copy", String(id)])
  }

  function deleteEntry(id) {
    deleteProc.command = ["bash", root.scriptPath, "delete", String(id)]
    deleteProc.running = true
  }

  function requestClear() {
    if (root.entries.length === 0) return
    root.clearConfirmOpen = true
  }

  function confirmClear() {
    root.clearConfirmOpen = false
    clearProc.running = true
  }

  function cancelClear() {
    root.clearConfirmOpen = false
  }

  function previewFor(entry) {
    if (entry.type === "image") return "🖼  Image (" + (entry.mime || "image") + ")"
    return String(entry.content || "").replace(/\s+/g, " ").trim()
  }

  function moveSelection(dy) {
    var count = root.entries.length
    if (count === 0) { root.selectedIndex = -1; return }
    if (root.selectedIndex < 0) { root.selectedIndex = dy > 0 ? 0 : count - 1 }
    else { root.selectedIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + dy)) }
    root.ensureSelectedVisible()
  }

  function activateSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.entries.length) return
    root.copyEntry(root.entries[root.selectedIndex].id)
    root.close()
  }

  // Column + Repeater isn't a ListView, so there's no positionViewAtIndex —
  // walk the selected delegate's position in the (unscrolled) column and
  // nudge contentY just enough to bring it back into the viewport.
  function ensureSelectedVisible() {
    if (root.selectedIndex < 0) return
    var item = entriesRepeater.itemAt(root.selectedIndex)
    if (!item) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    if (top < listScroll.contentY) {
      listScroll.contentY = top
    } else if (bottom > listScroll.contentY + listScroll.height) {
      listScroll.contentY = bottom - listScroll.height
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
    } else {
      root.searchQuery = ""
      searchInput.text = ""
      root.selectedIndex = -1
    }
  }

  Component.onCompleted: {
    initProc.running = true
  }

  Process { id: deleteProc; onExited: root.refresh() }
  Process { id: clearProc; command: ["bash", root.scriptPath, "clear"]; onExited: root.refresh() }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "").trim() || "[]")
          root.entries = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          root.entries = []
        }
        root.selectedIndex = -1
      }
    }
  }

  // Reap watchers left behind by a previous shell instance before starting
  // our own, same pattern the built-in clipboard history plugin uses.
  Process {
    id: initProc
    command: ["pkill", "-f", "wl-paste .*--watch .*copytracker/track\\.sh"]
    onExited: {
      root.refresh()
      textWatchProc.running = true
      imageWatchProc.running = true
    }
  }

  Process {
    id: textWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", "bash", root.scriptPath, "insert-text"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.refresh() }
    }
  }

  Process {
    id: imageWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", "bash", root.scriptPath, "insert-image", "image/png"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.refresh() }
    }
  }

  // A watcher that dies takes clipboard logging with it, silently — copying
  // still works, nothing recorded until the shell reloads. Bring it back.
  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!textWatchProc.running) textWatchProc.running = true
      if (!imageWatchProc.running) imageWatchProc.running = true
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.opened
    tooltipText: "Copy Tracker — " + root.entries.length + " entr" + (root.entries.length === 1 ? "y" : "ies")
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(Math.min(Style.space(480), column.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.clearConfirmOpen || searchInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.activateSelected()

      ConfirmDialog {
        anchors.fill: parent
        opened: root.clearConfirmOpen
        z: 10
        message: "Delete entire copy history?"
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.bar.foreground
        scrim: Color.menu.scrim
        selectedBackground: Color.menu.selectedBackground
        selectedText: Color.menu.selectedText
        fontFamily: root.bar.fontFamily
        cornerRadius: Style.cornerRadius
        onCanceled: root.cancelClear()
        onConfirmed: root.confirmClear()
      }

      Flickable {
        id: listScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: listScroll.width
          spacing: Style.space(12)

          // ---------- Header: title + clear-all ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, clearBtn.implicitHeight)

            Text {
              id: headerText
              text: "Copy Tracker (" + root.entries.length + ")"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Button {
              id: clearBtn
              text: "Clear All"
              bordered: true
              enabled: root.entries.length > 0
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.requestClear()
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          // ---------- Search ----------
          Item {
            width: parent.width
            implicitHeight: Style.space(32)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.bar.foreground, Color.accent)
              border.width: searchInput.activeFocus ? 1 : 0
              border.color: Color.accent
            }

            TextInput {
              id: searchInput
              anchors.fill: parent
              anchors.margins: Style.space(8)
              verticalAlignment: TextInput.AlignVCenter
              clip: true
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: {
                root.searchQuery = text
                searchDebounce.restart()
              }

              Text {
                visible: searchInput.text.length === 0
                text: "Search history..."
                opacity: 0.5
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Timer {
              id: searchDebounce
              interval: 150
              repeat: false
              onTriggered: root.refresh()
            }
          }

          // ---------- Empty state ----------
          Text {
            visible: root.entries.length === 0
            width: parent.width
            text: root.searchQuery.length > 0 ? "No matches for \"" + root.searchQuery + "\"" : "Nothing copied yet — copy something to see it here"
            opacity: 0.6
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---------- History ----------
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.entries.length > 0

            Repeater {
              id: entriesRepeater
              model: root.entries

              Item {
                id: rowItem
                required property var modelData
                required property int index

                width: parent.width
                implicitHeight: Style.space(50)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: (rowHover.containsMouse || rowItem.index === root.selectedIndex) ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
                }

                MouseArea {
                  id: rowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.copyEntry(rowItem.modelData.id); root.close() }
                }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: actions.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: root.previewFor(rowItem.modelData)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                  }

                  Text {
                    text: rowItem.modelData.created_at || ""
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  id: actions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Button {
                    text: "↺"
                    tooltipText: "Copy back to clipboard"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(4)
                    onClicked: { root.copyEntry(rowItem.modelData.id); root.close() }
                  }

                  Button {
                    text: "✕"
                    tooltipText: "Delete entry"
                    foreground: Qt.darker(root.bar.foreground, 1.4)
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(4)
                    onClicked: root.deleteEntry(rowItem.modelData.id)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
