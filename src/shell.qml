import QtQuick
import QtQuick.Window
import QtQuick.Effects
import Qt.labs.folderlistmodel

Window {
    id: main
    readonly property real ui: Screen.height / 1080
    readonly property real refWidth: 1920
    readonly property real refHeight: 500
    property int speed: 5000
    property int animDuration: 1000
    property real zoomScale: 0.8
    property real edgeScale: 0.3
    // A lean, as in the original. Applied as a matrix because QtQuick's Shear type
    // only exists in Qt 6.9 and newer, and Flow is built against the 6.8 LTS line.
    property real skewFactor: 0
    property real baseSpacing: 0
    property real edgeSpacing: 80
    property int startPosition: 4
    property bool shadowEnabled: true
    property color shadowColor: "#000000"
    property real shadowOpacity: 0.4
    property real shadowBlur: 0.45
    property real shadowX: 6
    property real shadowY: 6

    property bool showEmpty: false
    readonly property bool looksEmpty: folderModel.status === FolderListModel.Ready
                                       && folderModel.count === 0

    onLooksEmptyChanged: {
        if (looksEmpty) {
            emptyDelay.restart()
        } else {
            emptyDelay.stop()
            showEmpty = false
        }
    }

    visible: false
    color: "transparent"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    title: "Flow"

    // Stands in for the exclusive keyboard focus the Wayland layer gave the original:
    // once the picker loses focus it closes instead of lingering over the desktop.
    property bool wasActive: false
    onActiveChanged: {
        if (active) {
            wasActive = true
        } else if (wasActive) {
            // Closing mid-transition must still set the wallpaper that was picked.
            commitPending()
            Qt.quit()
        }
    }

    // The picked tile grows to fill the screen, the wallpaper is set behind it, then it fades away.
    property bool leaving: false
    property string pendingPath: ""

    function commitPending() {
        if (pendingPath === "") return
        const path = pendingPath
        pendingPath = ""
        backend.apply(path)
    }

    function beginReveal(tile, thumbUrl, fileUrl, filePath) {
        leaving = true
        pendingPath = filePath
        const from = tile.mapToItem(null, 0, 0)
        reveal.x = from.x
        reveal.y = from.y
        reveal.width = tile.width
        reveal.height = tile.height
        revealThumb.source = thumbUrl
        revealFull.source = fileUrl
        reveal.visible = true
        grow.start()
    }

    function settleReveal() {
        if (outro.running || !leaving || grow.running) return
        if (revealFull.status === Image.Loading) return
        fullTimeout.stop()
        outro.start()
    }

    Item {
        id: reveal
        z: 5
        visible: false
        clip: true

        Image {
            id: revealThumb
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            cache: false
            smooth: true
        }

        // The thumbnail carries the motion; the full image sharpens it once decoded.
        Image {
            id: revealFull
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutQuad } }
            onStatusChanged: main.settleReveal()
        }
    }

    Timer {
        id: fullTimeout
        interval: 2500
        onTriggered: if (!outro.running) outro.start()
    }

    ParallelAnimation {
        id: grow
        NumberAnimation { target: reveal; property: "x"; to: 0; duration: 520; easing.type: Easing.InOutCubic }
        NumberAnimation { target: reveal; property: "y"; to: 0; duration: 520; easing.type: Easing.InOutCubic }
        NumberAnimation { target: reveal; property: "width"; to: main.width; duration: 520; easing.type: Easing.InOutCubic }
        NumberAnimation { target: reveal; property: "height"; to: main.height; duration: 520; easing.type: Easing.InOutCubic }
        NumberAnimation { target: list; property: "opacity"; to: 0; duration: 280; easing.type: Easing.OutQuad }
        NumberAnimation { target: hints; property: "opacity"; to: 0; duration: 200 }
        onFinished: { fullTimeout.start(); main.settleReveal() }
    }

    SequentialAnimation {
        id: outro
        PauseAnimation { duration: 240 }
        ScriptAction { script: main.commitPending() }
        PauseAnimation { duration: 260 }
        NumberAnimation { target: reveal; property: "opacity"; to: 0; duration: 420; easing.type: Easing.InOutQuad }
        ScriptAction { script: Qt.quit() }
    }

    FolderListModel {
        id: folderModel
        folder: backend.wallpaperUrl
        showDirs: false
        // No webp: Windows cannot set one as the desktop wallpaper.
        nameFilters: ["*.png", "*.jpg", "*.jpeg"]
        sortField: FolderListModel.Name
    }

    // Almost invisible, but it keeps the empty area clickable on Windows.
    Rectangle {
        anchors.fill: parent
        color: "#03000000"
    }

    MouseArea {
        id: outsideClickArea
        anchors.fill: parent
        z: 0
        enabled: !main.leaving
        onClicked: Qt.quit()
    }

    Timer {
        id: emptyDelay
        interval: 300
        onTriggered: main.showEmpty = main.looksEmpty
    }

    Column {
        id: emptyState
        anchors.centerIn: parent
        spacing: 10 * main.ui
        z: 2
        visible: main.showEmpty

        Text {
            text: "No wallpapers found"
            color: "#ffffff"
            font.pixelSize: 22 * main.ui
            font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Text {
            text: "Add images to:"
            color: "#aaaaaa"
            font.pixelSize: 13 * main.ui
            anchors.horizontalCenter: parent.horizontalCenter
        }

        TextEdit {
            id: pathText
            text: backend.wallpaperPath
            color: "#dddddd"
            font.pixelSize: 14 * main.ui
            readOnly: true
            selectByMouse: true
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            text: "Open folder"
            color: "#ffffff"
            font.pixelSize: 14 * main.ui
            font.underline: true
            topPadding: 8 * main.ui
            anchors.horizontalCenter: parent.horizontalCenter

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { backend.openFolder(); Qt.quit() }
            }
        }
    }

    Text {
        id: hints
        visible: backend.showHints
        z: 2
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: list.bottom
        anchors.topMargin: 28 * main.ui
        text: "Click or Space to apply   ·   ← → to browse   ·   O to open wallpapers folder   ·   Esc to close"
        color: "#ffffff"
        opacity: 0.75
        style: Text.Outline
        styleColor: "#99000000"
        font.pixelSize: 13 * main.ui
    }

    ListView {
        id: list
        width: parent.width
        height: tileHeight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        z: 1
        focus: true
        model: folderModel
        orientation: ListView.Horizontal
        spacing: 0
        clip: true
        cacheBuffer: 400 * main.ui
        boundsBehavior: Flickable.StopAtBounds

        property int selectedIndex: main.startPosition

        readonly property real tileHeight: main.refHeight * main.ui
        readonly property real tileWidth: (main.refWidth / Math.max(1, backend.numberOfPictures) - 10) * main.ui

        readonly property real viewportCenterX: width / 2
        readonly property real falloffRadius: (main.refWidth / 2) * main.ui

        readonly property real step: tileWidth + main.baseSpacing * main.ui
        readonly property real sideMargin: Math.max(0, viewportCenterX - tileWidth / 2)
        property bool ready: false
        property bool userMoved: false

        leftMargin: sideMargin
        rightMargin: sideMargin

        function clampIndex(i) { return Math.max(0, Math.min(i, count - 1)) }
        function ensureVisibleAnimated(i) { contentX = i * step }

        function centerOnStart() {
            if (userMoved || count <= 0 || backend.numberOfPictures <= 0) return
            // A short row opens on its middle tile instead of leaning to one side.
            selectedIndex = clampIndex(Math.min(main.startPosition, Math.floor((count - 1) / 2)))
            contentX = selectedIndex * step
            ready = true
        }

        function activateCurrent() {
            if (count <= 0 || main.leaving) return
            const filePath = folderModel.get(selectedIndex, "filePath")
            const item = itemAtIndex(selectedIndex)
            if (!backend.transition || !item) {
                backend.apply(filePath)
                Qt.quit()
                return
            }
            enabled = false
            main.beginReveal(item.tile, item.thumbUrl, folderModel.get(selectedIndex, "fileUrl"), filePath)
        }

        function moveSelection(delta, speedMultiplier) {
            if (count <= 0) return
            userMoved = true
            anim.velocity = main.speed * speedMultiplier
            selectedIndex = clampIndex(selectedIndex + delta)
            ensureVisibleAnimated(selectedIndex)
        }

        onCountChanged: centerOnStart()
        onWidthChanged: centerOnStart()
        onTileWidthChanged: centerOnStart()

        Behavior on contentX {
            enabled: list.ready
            SmoothedAnimation { id: anim; property real velocity: main.speed; duration: main.animDuration }
        }

        delegate: Item {
            id: delegateItem
            width: list.tileWidth
            height: list.tileHeight

            property bool active: index === list.selectedIndex
            property alias tile: content
            readonly property string thumbUrl: backend.cacheUrl + encodeURIComponent(fileName)
            readonly property real baseWidth: list.tileWidth
            readonly property real baseCenterX: x - list.contentX + baseWidth / 2
            readonly property real distance: Math.abs(baseCenterX - list.viewportCenterX)
            readonly property real fraction: Math.min(1, distance / list.falloffRadius)
            readonly property real compression: { const t = fraction; return t * t * t * t }
            readonly property real edgeOffset: {
                const amount = main.edgeSpacing * main.ui * compression
                return baseCenterX < list.viewportCenterX ? amount : -amount
            }
            readonly property real scaleFactor: {
                const t = 1 - fraction * fraction * (3 - 2 * fraction)
                return main.edgeScale + (main.zoomScale - main.edgeScale) * t
            }

            Item {
                id: content
                anchors.verticalCenter: parent.verticalCenter
                width: delegateItem.baseWidth * delegateItem.scaleFactor
                height: delegateItem.height * Math.min(1, delegateItem.scaleFactor)
                x: (delegateItem.baseWidth - width) / 2 + delegateItem.edgeOffset

                Image {
                    id: shadowImage
                    x: main.shadowX * main.ui
                    y: main.shadowY * main.ui
                    width: parent.width
                    height: parent.height
                    source: img.source
                    sourceSize.width: img.sourceSize.width
                    sourceSize.height: img.sourceSize.height
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    smooth: true
                    visible: main.shadowEnabled
                    opacity: main.shadowOpacity
                    layer.enabled: true
                    layer.effect: MultiEffect { brightness: -1; blurEnabled: true; blur: main.shadowBlur }
                    transform: Matrix4x4 { matrix: Qt.matrix4x4(1, main.skewFactor, 0, 0,
                                                                   0, 1, 0, 0,
                                                                   0, 0, 1, 0,
                                                                   0, 0, 0, 1) }
                }

                Text {
                    id: alt
                    text: ""
                    color: backend.borderColor
                    anchors.centerIn: parent
                    font.pixelSize: 16 * main.ui
                    transform: Matrix4x4 { matrix: Qt.matrix4x4(1, main.skewFactor, 0, 0,
                                                                   0, 1, 0, 0,
                                                                   0, 0, 1, 0,
                                                                   0, 0, 0, 1) }
                }

                Image {
                    id: img
                    anchors.fill: parent
                    opacity: 0.95
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    smooth: true
                    source: delegateItem.thumbUrl
                    sourceSize.width: delegateItem.baseWidth * main.zoomScale
                    sourceSize.height: delegateItem.height
                    transform: Matrix4x4 { matrix: Qt.matrix4x4(1, main.skewFactor, 0, 0,
                                                                   0, 1, 0, 0,
                                                                   0, 0, 1, 0,
                                                                   0, 0, 0, 1) }

                    Timer {
                        id: retryTimer
                        interval: 1000
                        repeat: false
                        onTriggered: { const s = img.source; img.source = ""; img.source = s }
                    }

                    onStatusChanged: {
                        if (status === Image.Error) { alt.text = "Caching"; retryTimer.start() }
                    }
                }

                Rectangle {
                    z: 10
                    anchors.fill: parent
                    visible: delegateItem.active
                    color: "transparent"
                    border.width: Math.max(1, Math.round(2 * main.ui))
                    border.color: backend.borderColor
                    transform: Matrix4x4 { matrix: Qt.matrix4x4(1, main.skewFactor, 0, 0,
                                                                   0, 1, 0, 0,
                                                                   0, 0, 1, 0,
                                                                   0, 0, 0, 1) }
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: list.ready
                onEntered: { list.userMoved = true; list.selectedIndex = index }
                onClicked: list.activateCurrent()
                onWheel: function(wheel) { list.flick(-wheel.angleDelta.y * 8, 0); wheel.accepted = true }
            }
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                activateCurrent()
            } else if (event.key === Qt.Key_Left) {
                moveSelection(-1, 1)
            } else if (event.key === Qt.Key_Right) {
                moveSelection(1, 1)
            } else if (event.key === Qt.Key_O) {
                backend.openFolder()
                Qt.quit()
            } else if (event.key === Qt.Key_W || event.key === Qt.Key_Escape) {
                Qt.quit()
            } else {
                return
            }
            event.accepted = true
        }
    }
}
