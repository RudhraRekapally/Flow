// Flow - the wallpaper carousel.
// Copyright (c) 2026 Rudhra Rekapally. All rights reserved.
// Proprietary; see LICENSE.
//
// The row is laid out by hand rather than by one of Qt's views, because every view
// that scrolls a strip of items treats it as a loop, and this one has two ends: the
// first wallpaper and the last.
//
// There is a single number behind it, `cursor`, which says which card is in the
// middle. It is a real number, not an integer, so animating it slides the whole row.
// Each card then reads its own distance from the cursor and looks up where it sits
// and how big it is, interpolating between the entries of a small table. The table
// is the shape of the row: the selected card is the biggest, and the rest shrink and
// bunch up towards the edges of the screen.

import QtQuick
import QtQuick.Window
import QtQuick.Effects
import Qt.labs.folderlistmodel

Window {
    id: root

    title: "Flow"
    visible: false
    color: "transparent"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint

    // Everything is drawn for a 1080p screen and scaled from there.
    readonly property real unit: Screen.height / 1080
    readonly property real reference: 1920

    readonly property int across: Math.max(3, backend.tiles)
    // One card's share of the row, less a hair of air between them.
    readonly property real slot: (reference / across - 10) * unit
    readonly property real cardHeight: 500 * unit
    readonly property real midX: width / 2
    readonly property real midY: height / 2

    // How far out from the middle a card is still worth drawing.
    readonly property int reach: 5

    // The shape of the row, read off at whole steps from the middle: how far out the
    // card sits, in slots, and how big it is. Between the steps the two are
    // interpolated, which is what makes the row slide smoothly rather than jump.
    readonly property var stops: [0.000, 1.100, 2.030, 2.970, 3.865, 4.650]
    readonly property var sizes: [1.080, 0.720, 0.600, 0.480, 0.370, 0.300]
    // Carries the table on past its last entry, for cards on their way off screen.
    readonly property real tailStep: 0.785

    function sample(table, distance, beyond) {
        const last = table.length - 1
        if (distance >= last)
            return table[last] + (distance - last) * beyond
        const step = Math.floor(distance)
        return table[step] + (table[step + 1] - table[step]) * (distance - step)
    }

    function placeAt(distance) { return sample(stops, distance, tailStep) }
    function sizeAt(distance) { return sample(sizes, distance, 0) }

    // The picker is a transient overlay: once it is no longer the active window it
    // has been dismissed, so it closes rather than hang over the desktop.
    property bool everActive: false
    onActiveChanged: {
        if (active) {
            everActive = true
        } else if (everActive) {
            setChosen()       // a dismissal mid-animation still honours the pick
            Qt.quit()
        }
    }

    // ---------------------------------------------------------------- choosing

    // The picked card's own picture grows to fill the screen: it slides to the
    // middle and scales up while the frame around it opens out, so nothing is ever
    // re-cropped on the way. Then the wallpaper is set behind it and it fades into
    // the desktop, which by then is showing the same picture.
    property string chosen: ""
    property bool zooming: false
    property real grown: 0                  // 0: the card, 1: the whole screen
    property rect from: Qt.rect(0, 0, 0, 0)
    property real startScale: 1

    function setChosen() {
        if (chosen === "") return
        const path = chosen
        chosen = ""
        sent = true
        backend.apply(path)
    }

    function pick(card, thumb, full, path) {
        if (zooming || !card) return
        if (!backend.transition) {
            backend.apply(path)
            Qt.quit()
            return
        }
        zooming = true
        chosen = path

        // Corner to corner, so the card's own scale is folded into the rectangle.
        const topLeft = card.mapToItem(null, 0, 0)
        const bottomRight = card.mapToItem(null, card.width, card.height)
        from = Qt.rect(topLeft.x, topLeft.y, bottomRight.x - topLeft.x, bottomRight.y - topLeft.y)

        // How much smaller the picture is on the card than it will be on the screen.
        // The card fills a tall frame and the screen a wide one, so each is the
        // larger of its two fits; their ratio is where the zoom starts.
        zoomThumb.source = thumb
        const w = zoomThumb.implicitWidth
        const h = zoomThumb.implicitHeight
        if (w > 0 && h > 0)
            startScale = Math.max(from.width / w, from.height / h) / Math.max(width / w, height / h)
        else
            startScale = from.height / height

        grown = 0
        zoom.opacity = 1
        zoomFull.source = full
        zoom.visible = true
        openUp.start()
    }

    // The way out: set the wallpaper, wait until the system says it is done, give the
    // desktop a moment to draw it, and only then fade the picture away. Fading any
    // sooner shows the old wallpaper for an instant, which macOS is slow enough to do.
    property bool sent: false       // the wallpaper has been asked for
    property bool leaving: false
    property bool fading: false

    function finishZoom() {
        if (!zooming || openUp.running) return
        if (zoomFull.status === Image.Loading) return   // let the full image land first
        leave()
    }

    function leave() {
        if (leaving) return
        leaving = true
        patience.stop()
        bowOut.start()
    }

    function fadeOut() {
        if (!sent || fading) return
        fading = true
        landing.stop()
        settle.start()
    }

    Connections {
        target: backend
        function onApplied() { root.fadeOut() }
    }

    // ---------------------------------------------------------------- the files

    FolderListModel {
        id: files
        folder: backend.folderUrl
        showDirs: false
        // The file types this system can set as a wallpaper, in any case: IMG_0042.JPG counts.
        nameFilters: backend.patterns
        caseSensitive: false
        sortField: FolderListModel.Name
    }

    readonly property bool noFiles: files.status === FolderListModel.Ready && files.count === 0

    // ---------------------------------------------------------------- backdrop

    Rectangle {
        anchors.fill: parent
        // All but invisible, and enough for Windows to treat the window as solid
        // so clicks land here instead of falling through to the desktop.
        color: "#03000000"
    }

    // ---------------------------------------------------------------- carousel

    Item {
        id: strip

        anchors.fill: parent
        focus: true
        opacity: root.zooming ? 0 : 1
        enabled: !root.zooming
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }

        // Which card is in the middle. `current` is the selection; `cursor` is where
        // the row has actually slid to, and catches up to it.
        property int current: 0
        property real cursor: 0
        property bool placed: false

        onCurrentChanged: cursor = current

        Behavior on cursor {
            enabled: strip.placed
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }

        // The row opens a little left of middle, and on the middle card when there
        // are too few to fill it. No animation for that first placement.
        Connections {
            target: files
            function onCountChanged() {
                if (strip.placed || files.count <= 0) return
                strip.current = Math.min(4, Math.floor((files.count - 1) / 2))
                strip.cursor = strip.current
                strip.placed = true
            }
        }

        // The ends are ends: asking for a card that is not there does nothing, so the
        // row can never run off into empty space.
        function step(delta) {
            const next = current + delta
            if (files.count <= 0 || next < 0 || next >= files.count) return
            current = next
        }

        function choose() {
            const card = cards.itemAt(current)
            if (files.count <= 0 || !card) return
            root.pick(card.frame, card.thumbUrl, card.fileUrl, card.filePath)
        }

        // The card under a point, picking the one drawn on top where two overlap.
        function cardAt(x, y) {
            let found = -1
            let depth = -Infinity
            const low = Math.max(0, current - root.reach - 1)
            const high = Math.min(files.count - 1, current + root.reach + 1)
            for (let i = low; i <= high; i++) {
                const card = cards.itemAt(i)
                if (!card || !card.visible) continue
                const p = card.mapFromItem(strip, x, y)
                if (card.contains(p) && card.z > depth) {
                    found = i
                    depth = card.z
                }
            }
            return found
        }

        // A click on a side card brings it to the middle; a click on the middle card
        // applies it, and so does a double-click on any card. The row slides between
        // the two clicks of a double-click, so the second one lands on whatever card
        // moved under the pointer: it counts for the card the first click picked.
        property int armed: -1
        property real armedTime: 0
        property point armedPoint: Qt.point(0, 0)

        TapHandler {
            enabled: !root.zooming
            onTapped: function (eventPoint) {
                const p = eventPoint.position
                const quick = Date.now() - strip.armedTime <= Qt.styleHints.mouseDoubleClickInterval
                const still = Math.abs(p.x - strip.armedPoint.x) < 12 * root.unit
                    && Math.abs(p.y - strip.armedPoint.y) < 12 * root.unit
                if (strip.armed >= 0 && quick && still) {
                    strip.current = strip.armed
                    strip.armed = -1
                    strip.choose()
                    return
                }
                strip.armed = -1
                const i = strip.cardAt(p.x, p.y)
                if (i < 0) {
                    Qt.quit()                   // a click on the empty desktop closes
                } else if (i === strip.current) {
                    strip.choose()
                } else {
                    strip.current = i
                    strip.armed = i
                    strip.armedTime = Date.now()
                    strip.armedPoint = p
                }
            }
        }

        // The row moves with the wheel and the arrow keys only; the mouse pointer
        // passing over a card leaves the selection alone.
        WheelHandler {
            onWheel: function (event) {
                if (event.angleDelta.y > 0)
                    strip.step(-1)
                else if (event.angleDelta.y < 0)
                    strip.step(1)
            }
        }

        Keys.onLeftPressed: strip.step(-1)
        Keys.onRightPressed: strip.step(1)
        Keys.onSpacePressed: strip.choose()
        Keys.onReturnPressed: strip.choose()
        Keys.onEnterPressed: strip.choose()
        Keys.onEscapePressed: Qt.quit()
        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_O) {
                backend.openFolder()
                Qt.quit()
            } else if (event.key === Qt.Key_W) {
                Qt.quit()
            } else if (event.key === Qt.Key_Home) {
                strip.current = 0
            } else if (event.key === Qt.Key_End) {
                strip.current = files.count - 1
            } else {
                return
            }
            event.accepted = true
        }

        Repeater {
            id: cards
            model: files

            delegate: Item {
                id: card

                required property int index
                required property string fileName
                required property string filePath
                required property url fileUrl

                readonly property url thumbUrl: backend.thumbsUrl + encodeURIComponent(fileName)
                readonly property Item frame: body
                readonly property bool current: index === strip.current

                // Signed distance from the middle of the row.
                readonly property real gap: index - strip.cursor
                readonly property real away: Math.abs(gap)
                // Far enough out to be off screen, but still worth keeping decoded
                // so it is already there when it slides back in.
                readonly property bool near: away < root.reach + 2

                width: root.slot
                height: root.cardHeight
                x: root.midX + Math.sign(gap) * root.placeAt(away) * root.slot - width / 2
                y: root.midY - height / 2
                scale: root.sizeAt(away)
                visible: away < root.reach + 1
                // The middle card sits above its neighbours, so the one that is
                // selected is the one on top.
                z: Math.round(100 - away * 10)

                // A blurred slab behind the photo. The inset leaves the layer room
                // for the blur to spread into instead of being cut off at its edge.
                Item {
                    x: 6 * root.unit
                    y: 6 * root.unit
                    width: parent.width
                    height: parent.height
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blur: 0.45
                        blurMax: 24
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 8 * root.unit
                        color: "#000000"
                        opacity: 0.4
                    }
                }

                Item {
                    id: body
                    anchors.fill: parent
                    clip: true

                    // Stands in until the thumbnail has been written, and shows
                    // through anywhere the photo does not reach.
                    Rectangle {
                        anchors.fill: parent
                        color: "#1b1b1f"
                        visible: photo.status !== Image.Ready

                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 16
                            text: card.fileName
                            color: "#6f6f78"
                            font.pixelSize: 11 * root.unit
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 3
                        }
                    }

                    Image {
                        id: photo
                        anchors.fill: parent
                        source: card.near ? card.thumbUrl : ""
                        fillMode: Image.PreserveAspectCrop
                        // Decoded at the size the middle card is drawn, in real screen
                        // pixels, so the card in focus is never an upscaled picture.
                        sourceSize.height: Math.ceil(root.cardHeight * root.sizes[0] * Screen.devicePixelRatio)
                        asynchronous: true
                        // Kept in Qt's image cache, so a card sliding back into view
                        // does not decode its thumbnail all over again.
                        cache: true
                        smooth: true
                        // The side cards are drawn well below that size; mipmaps keep
                        // them clean instead of shimmering.
                        mipmap: true
                        opacity: status === Image.Ready ? 0.95 : 0
                        Behavior on opacity { NumberAnimation { duration: 160 } }
                    }

                    Rectangle {
                        anchors.fill: parent
                        visible: card.current && backend.highlight !== "transparent"
                        color: "transparent"
                        border.width: Math.max(1, Math.round(2 * root.unit))
                        border.color: backend.highlight
                    }
                }

                // The first run has no thumbnails yet; each one says when it is
                // ready rather than every card sitting on a retry timer.
                Connections {
                    target: backend
                    function onThumbnailReady(name) {
                        if (name !== card.fileName || photo.status === Image.Ready) return
                        photo.source = ""
                        photo.source = card.near ? card.thumbUrl : ""
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- captions

    Text {
        visible: backend.showHints && !root.noFiles
        opacity: root.zooming ? 0 : 0.75
        z: 2
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.midY + root.cardHeight / 2 + 40 * root.unit
        text: "Double-click or Enter to apply   ·   ← → to browse   ·   O to open wallpapers folder   ·   Esc to close"
        color: "#ffffff"
        style: Text.Outline
        styleColor: "#99000000"
        font.pixelSize: 13 * root.unit
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    // A folder being read briefly looks empty; wait before saying so.
    property bool sayEmpty: false
    onNoFilesChanged: {
        if (noFiles) {
            emptyPause.restart()
        } else {
            emptyPause.stop()
            sayEmpty = false
        }
    }

    Timer {
        id: emptyPause
        interval: 300
        onTriggered: root.sayEmpty = root.noFiles
    }

    Column {
        z: 2
        visible: root.sayEmpty
        anchors.centerIn: parent
        spacing: 10 * root.unit

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No wallpapers found"
            color: "#ffffff"
            font.pixelSize: 22 * root.unit
            font.bold: true
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Add images to:"
            color: "#aaaaaa"
            font.pixelSize: 13 * root.unit
        }

        TextEdit {
            anchors.horizontalCenter: parent.horizontalCenter
            text: backend.folderPath
            color: "#dddddd"
            font.pixelSize: 14 * root.unit
            readOnly: true
            selectByMouse: true
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Open folder"
            color: "#ffffff"
            font.pixelSize: 14 * root.unit
            font.underline: true
            topPadding: 8 * root.unit

            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: { backend.openFolder(); Qt.quit() } }
        }
    }

    // ---------------------------------------------------------------- the zoom

    // The frame: opens out from the card's rectangle to the whole screen.
    Item {
        id: zoom
        z: 5
        visible: false
        clip: true
        x: root.from.x * (1 - root.grown)
        y: root.from.y * (1 - root.grown)
        width: root.from.width + (root.width - root.from.width) * root.grown
        height: root.from.height + (root.height - root.from.height) * root.grown

        // The picture: always laid out at full-screen size and cropped as the
        // desktop will crop it, then moved and scaled. Its middle travels from the
        // card's middle to the screen's.
        Item {
            readonly property real fromX: root.from.x + root.from.width / 2
            readonly property real fromY: root.from.y + root.from.height / 2

            width: root.width
            height: root.height
            x: fromX + (root.midX - fromX) * root.grown - root.midX - zoom.x
            y: fromY + (root.midY - fromY) * root.grown - root.midY - zoom.y
            scale: root.startScale + (1 - root.startScale) * root.grown

            Image {
                id: zoomThumb
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                // Loaded on the spot: its size sets where the zoom starts.
                asynchronous: false
                cache: true
                smooth: true
            }

            // The thumbnail carries the movement; the real file sharpens it on arrival.
            Image {
                id: zoomFull
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: root.width
                sourceSize.height: root.height
                asynchronous: true
                cache: false
                smooth: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                onStatusChanged: root.finishZoom()
            }
        }
    }

    // A very large photo must not hold the animation up for ever.
    Timer {
        id: patience
        interval: 2500
        onTriggered: root.leave()
    }

    NumberAnimation {
        id: openUp
        target: root
        property: "grown"
        from: 0
        to: 1
        duration: 480
        easing.type: Easing.InOutCubic
        onFinished: { patience.start(); root.finishZoom() }
    }

    SequentialAnimation {
        id: bowOut
        PauseAnimation { duration: 180 }            // the full image finishes sharpening
        ScriptAction { script: { root.setChosen(); landing.start() } }
    }

    // The system never said the wallpaper was set; leave anyway.
    Timer {
        id: landing
        interval: 4000
        onTriggered: root.fadeOut()
    }

    SequentialAnimation {
        id: settle
        // The desktop draws the new picture behind us. macOS takes a while after it
        // reports the change; Windows has drawn it by the time it returns.
        PauseAnimation { duration: backend.settleMs }
        NumberAnimation { target: zoom; property: "opacity"; to: 0; duration: 380; easing.type: Easing.OutQuad }
        ScriptAction { script: Qt.quit() }
    }
}
