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

  function pasteEntry(id) {
    Quickshell.execDetached(["bash", root.scriptPath, "paste", String(id)])
  }

  // Puts the entry on the clipboard without pasting or closing the panel,
  // for grabbing something to paste manually (or grabbing several in a row).
  function copyEntry(id) {
    Quickshell.execDetached(["bash", root.scriptPath, "copy", String(id)])
  }

  function copySelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.entries.length) return
    root.copyEntry(root.entries[root.selectedIndex].id)
  }

  function deleteEntry(id) {
    deleteProc.command = ["bash", root.scriptPath, "delete", String(id)]
    deleteProc.running = true
  }

  function setPinned(id, pinned) {
    pinProc.command = ["bash", root.scriptPath, pinned ? "pin" : "unpin", String(id)]
    pinProc.running = true
  }

  function togglePinSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.entries.length) return
    var entry = root.entries[root.selectedIndex]
    root.setPinned(entry.id, !entry.pinned)
  }

  function requestClear() {
    if (!root.entries.some(function(e) { return !e.pinned })) return
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
    if (entry.type === "image") return "Image (" + (entry.mime || "image") + ")"
    // Some apps (Google Docs, etc.) put HTML on the text/plain clipboard
    // target instead of real plain text. Strip tags (before truncating —
    // truncating first can cut a long data-URI <img> tag off before its
    // closing '>', leaving a dangling tag the regex can't match) so a
    // stray <img> can't get interpreted as rich content by Text below.
    return String(entry.content || "").replace(/<[^>]*>/g, " ").slice(0, 500).replace(/\s+/g, " ").trim()
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
    root.pasteEntry(root.entries[root.selectedIndex].id)
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
  Process { id: pinProc; onExited: root.refresh() }

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
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image", "--watch", "bash", root.scriptPath, "insert-image"]
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
      onTextKey: function(t) {
        if (t === "p" || t === "P") root.togglePinSelected()
        else if (t === "c" || t === "C") root.copySelected()
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.clearConfirmOpen
        z: 10
        message: "Delete all unpinned copy history?"
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
              enabled: root.entries.some(function(e) { return !e.pinned })
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
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: clearSearchBtn.left
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

            Button {
              id: clearSearchBtn
              visible: searchInput.text.length > 0
              text: "✕"
              tooltipText: "Clear search"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: { searchInput.text = ""; searchInput.forceActiveFocus() }
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
            textFormat: Text.PlainText
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
                  color: {
                    if (rowHover.containsMouse || rowItem.index === root.selectedIndex)
                      return Style.hoverFillFor(root.bar.foreground, Color.accent)
                    if (rowItem.modelData.pinned)
                      return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
                    return "transparent"
                  }
                }

                MouseArea {
                  id: rowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.pasteEntry(rowItem.modelData.id); root.close() }
                }

                Item {
                  id: infoArea
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: actions.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(36)

                  Item {
                    id: thumb
                    visible: rowItem.modelData.type === "image"
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? Style.space(36) : 0
                    height: Style.space(36)
                    clip: true

                    Image {
                      anchors.fill: parent
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      sourceSize.width: 96
                      sourceSize.height: 96
                      source: thumb.visible ? "file://" + rowItem.modelData.content : ""
                    }
                  }

                  Column {
                    anchors.left: thumb.visible ? thumb.right : parent.left
                    anchors.leftMargin: thumb.visible ? Style.space(8) : 0
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: root.previewFor(rowItem.modelData)
                      textFormat: Text.PlainText
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
                }

                Row {
                  id: actions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Button {
                    text: rowItem.modelData.pinned ? "★" : "☆"
                    tooltipText: rowItem.modelData.pinned ? "Unpin" : "Pin"
                    foreground: rowItem.modelData.pinned ? Color.accent : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(4)
                    onClicked: root.setPinned(rowItem.modelData.id, !rowItem.modelData.pinned)
                  }

                  Button {
                    text: "↺"
                    tooltipText: "Paste"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(4)
                    onClicked: { root.pasteEntry(rowItem.modelData.id); root.close() }
                  }

                  Button {
                    text: "⧉"
                    tooltipText: "Copy (without pasting)"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(4)
                    onClicked: root.copyEntry(rowItem.modelData.id)
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
