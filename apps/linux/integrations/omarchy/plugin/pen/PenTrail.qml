pragma ComponentBehavior: Bound
import QtQuick
import "PenGeometry.js" as Ink

Item {
    id: root
    property var gesture: null
    readonly property var points: gesture ? gesture.points : []
    readonly property var origin: points.length ? points[0] : ({ x: 0, y: 0 })
    readonly property var tip: points.length ? points[points.length - 1] : origin
    readonly property bool tracking: gesture !== null && ["start", "move"].includes(gesture.phase)
    readonly property bool cancelled: gesture !== null && ["cancel", "failure", "noop"].includes(gesture.phase)
    readonly property bool returnShape: gesture !== null && gesture.direction === "down_left"
    property real commitProgress: 0
    property var path: []
    property var widths: []
    property var hand: []
    property var handWidths: []
    property var clean: []
    property var cleanWidths: []
    property var cells: []
    property string latticeKey: ""
    property string pathKey: ""
    property int lastId: -1
    property bool wasTracking: true

    function refresh() {
        if (!gesture || !gesture.points.length) return;
        // Read the new packet directly: dependent QML bindings can still have
        // their previous values inside onGestureChanged.
        var raw = gesture.points;
        var nextTracking = ["start", "move"].includes(gesture.phase);
        var nextCancelled = ["cancel", "failure", "noop"].includes(gesture.phase);
        var key = gesture.id + ":" + raw.map(function(p) { return p.x + "," + p.y; }).join(";");
        if (key !== pathKey) {
            pathKey = key;
            path = Ink.smooth(raw);
            widths = Ink.liveWidths(path);
            hand = Ink.resample(path, 96);
            handWidths = Ink.liveWidths(hand);
            clean = Ink.cleaned(path, gesture.direction);
            cleanWidths = Ink.penWidths(clean);
            var touched = Ink.touchedCells(raw), nextKey = Ink.gridKey(touched, raw);
            if (nextKey !== latticeKey) {
                latticeKey = nextKey; cells = Ink.lattice(touched); grid.requestPaint();
            }
        }
        if (lastId !== gesture.id || nextTracking) { redraw.stop(); commitProgress = 0; }
        if (!nextTracking && !nextCancelled && (lastId !== gesture.id || wasTracking)) redraw.restart();
        lastId = gesture.id; wasTracking = nextTracking;
        canvas.requestPaint();
    }
    onGestureChanged: refresh()
    onCommitProgressChanged: canvas.requestPaint()
    onWidthChanged: { canvas.requestPaint(); grid.requestPaint(); }
    onHeightChanged: { canvas.requestPaint(); grid.requestPaint(); }
    Component.onCompleted: refresh()
    NumberAnimation { id: redraw; target: root; property: "commitProgress"; from: 0; to: 1; duration: 300 }

    Canvas {
        id: grid
        anchors.fill: parent
        opacity: 0.25 * (root.cancelled ? 0 : root.tracking ? 1 : 1 - Ink.ease(root.commitProgress))
        onPaint: {
            var ctx = getContext("2d"); ctx.reset(); ctx.clearRect(0, 0, width, height);
            var a = root.origin, b = root.tip;
            var hc = Math.round((b.x-a.x)/20), hr = Math.round((b.y-a.y)/20);
            root.cells.forEach(function(cell) {
                var x = a.x + cell.c * 20 - 8, y = a.y + cell.r * 20 - 8;
                if (x < -16 || y < -16 || x > width || y > height) return;
                ctx.fillStyle = "rgba(242,242,242," + (cell.c === hc && cell.r === hr && root.points.length > 1 ? 0.5 : cell.alpha) + ")";
                ctx.beginPath();
                ctx.moveTo(x+3.5,y); ctx.lineTo(x+12.5,y); ctx.quadraticCurveTo(x+16,y,x+16,y+3.5);
                ctx.lineTo(x+16,y+12.5); ctx.quadraticCurveTo(x+16,y+16,x+12.5,y+16);
                ctx.lineTo(x+3.5,y+16); ctx.quadraticCurveTo(x,y+16,x,y+12.5);
                ctx.lineTo(x,y+3.5); ctx.quadraticCurveTo(x,y,x+3.5,y); ctx.fill();
            });
        }
    }
    Canvas {
        id: canvas
        anchors.fill: parent
        function dot(ctx, p, r, color) { ctx.fillStyle = color; ctx.beginPath(); ctx.arc(p.x, p.y, r, 0, 2*Math.PI); ctx.fill(); }
        function ribbon(ctx, path, widths, extra, color) {
            if (path.length < 2) return;
            var left = [], right = [];
            for (var i = 0; i < path.length; ++i) {
                var a = path[Math.max(0,i-1)], b = path[Math.min(path.length-1,i+1)];
                var dx=b.x-a.x, dy=b.y-a.y, len=Math.max(0.001,Math.hypot(dx,dy)), half=(widths[i]+extra)/2;
                left.push({x:path[i].x-dy/len*half,y:path[i].y+dx/len*half});
                right.push({x:path[i].x+dy/len*half,y:path[i].y-dx/len*half});
            }
            ctx.fillStyle=color; ctx.beginPath(); ctx.moveTo(left[0].x,left[0].y);
            for (var j=1;j<left.length;++j) ctx.lineTo(left[j].x,left[j].y);
            for (var k=right.length-1;k>=0;--k) ctx.lineTo(right[k].x,right[k].y);
            ctx.closePath(); ctx.fill();
            dot(ctx,path[0],(widths[0]+extra)/2,color);
            dot(ctx,path[path.length-1],(widths[widths.length-1]+extra)/2,color);
        }
        function head(ctx,p,alpha) {
            // A small tilted nib in the ink, rather than a glowing cursor orb.
            ctx.save(); ctx.globalAlpha=alpha;
            ctx.translate(p.x,p.y); ctx.rotate(-Math.PI*0.22);
            ctx.beginPath(); ctx.moveTo(-4.5,-1.4); ctx.lineTo(3.8,-1.4);
            ctx.lineTo(4.5,1.4); ctx.lineTo(-3.8,1.4); ctx.closePath();
            ctx.fillStyle="#ef6a47"; ctx.fill();
            ctx.beginPath(); ctx.moveTo(-3.6,-1.0); ctx.lineTo(2.8,-1.0);
            ctx.strokeStyle="rgba(255,241,227,0.65)"; ctx.lineWidth=0.65; ctx.stroke();
            ctx.restore();
        }
        function ink(ctx,line,widths) {
            ribbon(ctx,line,widths,2.2,"rgba(0,0,0,0.22)");
            ribbon(ctx,line,widths,0,"#f2efe9");
            // A very faint narrow groove gives the broad nib some ink texture.
            // Keep it within broad sections so hairlines stay clean.
            ctx.beginPath();
            var drawing=false;
            for (var i=0;i<line.length;++i) {
                if (widths[i]<4.8) { drawing=false; continue; }
                var a=line[Math.max(0,i-1)], b=line[Math.min(line.length-1,i+1)];
                var dx=b.x-a.x,dy=b.y-a.y,len=Math.max(0.001,Math.hypot(dx,dy));
                var x=line[i].x-dy/len*widths[i]*0.22, y=line[i].y+dx/len*widths[i]*0.22;
                if (drawing) ctx.lineTo(x,y); else ctx.moveTo(x,y);
                drawing=true;
            }
            ctx.strokeStyle="rgba(88,78,65,0.15)"; ctx.lineWidth=0.6; ctx.lineCap="round"; ctx.stroke();
        }
        onPaint: {
            var ctx=getContext("2d"); ctx.reset(); ctx.clearRect(0,0,width,height);
            if (!root.points.length) return;
            if (root.cancelled) {
                var dots=Ink.resample(root.path,Math.min(2048,Math.max(2,Math.ceil(Ink.length(root.path)/9))));
                dots.forEach(function(p) { canvas.dot(ctx,p,1.5,"rgba(242,242,242,0.4)"); });
                return;
            }
            if (root.tracking) {
                ctx.beginPath(); ctx.arc(root.origin.x,root.origin.y,2.8,0,2*Math.PI);
                ctx.strokeStyle="rgba(0,0,0,0.22)"; ctx.lineWidth=2.5; ctx.stroke();
                ctx.strokeStyle="rgba(242,239,233,0.4)"; ctx.lineWidth=0.8; ctx.stroke();
                ink(ctx,root.path,root.widths);
                if (root.points.length>1) head(ctx,root.tip,1);
            } else {
                // Let the whole ink mark settle and lift to a hairline. Avoid
                // erasing it and replaying a cursor from the beginning.
                var t=Ink.ease(root.commitProgress), line=[], widths=[];
                for (var i=0;i<root.clean.length;++i) {
                    line.push(Ink.mix(root.hand[i],root.clean[i],t));
                    widths.push(root.handWidths[i]+(root.cleanWidths[i]-root.handWidths[i])*t);
                }
                ink(ctx,line,widths);
                if (line.length && t<1) head(ctx,line[line.length-1],1-t);
            }
        }
    }

    Repeater {
        model: [{dir:"up",title:"Fab recording"},{dir:"left",title:"Previous space"},{dir:"right",title:"Next space"},{dir:"down",title:"Lattices overlay"}]
        Text {
            required property var modelData
            readonly property bool armed: root.gesture !== null && root.gesture.ready && root.gesture.direction === modelData.dir
            readonly property bool heading: root.gesture !== null && root.gesture.direction === modelData.dir
            readonly property real reach: Math.max(Math.abs(root.tip.x-root.origin.x),Math.abs(root.tip.y-root.origin.y))
            readonly property real anchorX: root.origin.x + (modelData.dir === "left" ? -110 : modelData.dir === "right" ? 110 : 20)
            readonly property real anchorY: root.origin.y + (modelData.dir === "up" ? -110 : modelData.dir === "down" ? 110 : -20)
            readonly property real penGap: Math.hypot(Math.max(x-root.tip.x,0,root.tip.x-x-width),Math.max(y-root.tip.y,0,root.tip.y-y-height))
            visible: root.tracking && !root.gesture.testing && !root.returnShape
            x: Math.round(Math.max(12,Math.min(root.width-width-12,anchorX-(modelData.dir === "left" ? width : 0))))
            y: Math.round(Math.max(12,Math.min(root.height-height-12,anchorY-height/2)))
            opacity: (root.gesture && root.gesture.ready ? (armed ? 0.85 : 0.12) : heading ? 0.32+0.2*Math.min(1,reach/80) : 0.26) * Math.max(0.15,Math.min(1,penGap/28))
            text: modelData.title; textFormat: Text.PlainText
            color: "#f2f2f2"; style: Text.Outline; styleColor: "#99000000"
            font.family: "sans-serif"; font.pixelSize: 13; font.weight: Font.Medium
        }
    }

    Rectangle {
        objectName: "gestureOutcome"
        readonly property bool horizontal: root.gesture && ["left","right"].includes(root.gesture.direction)
        readonly property real shapeBottom: root.points.reduce(function(value,p) { return Math.max(value,p.y); },0)
        readonly property real shapeTop: root.points.reduce(function(value,p) { return Math.min(value,p.y); },root.height)
        readonly property real anchorX: root.cancelled || root.returnShape || root.gesture && root.gesture.testing ? root.tip.x+14 : root.origin.x + (horizontal ? (root.gesture.direction === "left" ? -110-width : 110) : 20)
        readonly property real anchorY: root.returnShape ? (shapeBottom+height+30 < root.height ? shapeBottom+18 : shapeTop-height-18) : root.cancelled || root.gesture && root.gesture.testing ? root.tip.y-height-14 : root.origin.y + (horizontal ? -20 : root.gesture && root.gesture.direction === "up" ? -110 : 110)-height/2
        visible: root.gesture !== null && (!root.tracking || root.gesture.testing || root.returnShape)
        x: Math.round(Math.max(12,Math.min(root.width-width-12,anchorX)))
        y: Math.round(Math.max(12,Math.min(root.height-height-12,anchorY)))
        width: Math.min(root.width-24,copy.implicitWidth+24); height: 30; radius: 9
        color: "#f00d1013"; border.color: "#24f2f2f2"
        Row {
            id: copy
            x: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 10
            Text {
                color: root.gesture && root.gesture.phase === "failure" ? "#ef6a47" : "#f2f2f2"
                font.family: "sans-serif"; font.pixelSize: 13; font.weight: Font.Medium
                textFormat: Text.PlainText
                text: !root.gesture ? "" : root.gesture.testing ? root.gesture.buttonName + " · " + root.gesture.button : root.gesture.phase === "cancel" ? "No gesture" : root.gesture.label
                width: Math.min(implicitWidth,root.width-170); elide: Text.ElideRight
            }
            Text {
                color: "#80f2f2f2"; font.family: "monospace"; font.pixelSize: 11; textFormat: Text.PlainText
                text: !root.gesture ? "" : root.gesture.testing ? "test only · Esc exits" : root.tracking && root.returnShape ? (root.gesture.ready ? "release to send" : "down 80px · left 80px") : root.gesture.phase === "pending" ? "working…" : root.gesture.phase === "commit" ? "sent" : ""
            }
        }
    }
}
