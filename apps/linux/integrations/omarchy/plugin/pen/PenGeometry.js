// Based on Lattices' Mac Ink renderer, with a broader pen and a gentle nib lift.
// Geometry stays independent of recognition: Linux retains its 80px threshold.
function distance(a, b) { return Math.hypot(b.x - a.x, b.y - a.y); }
function mix(a, b, t) { return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }; }
function length(path) {
    var total = 0;
    for (var i = 1; i < path.length; ++i) total += distance(path[i - 1], path[i]);
    return total;
}
function resample(path, count) {
    if (!path.length || count < 2) return path.slice();
    var total = length(path), out = [path[0]], segment = 1, walked = 0;
    if (total < 0.001) {
        while (out.length < count) out.push(path[0]);
        return out;
    }
    for (var i = 1; i < count - 1; ++i) {
        var target = total * i / (count - 1);
        while (segment < path.length - 1 && walked + distance(path[segment - 1], path[segment]) < target) {
            walked += distance(path[segment - 1], path[segment]);
            ++segment;
        }
        var span = distance(path[segment - 1], path[segment]);
        out.push(mix(path[segment - 1], path[segment], span < 0.001 ? 0 : (target - walked) / span));
    }
    out.push(path[path.length - 1]);
    return out;
}
function smooth(path) {
    if (path.length < 4) return path.slice();
    // A small local filter keeps the elbow of short gestures. The previous
    // seven-point average could turn a sparsely sampled return into a diagonal.
    var out = path.map(function(point, i) {
        if (i === 0 || i === path.length - 1) return point;
        return { x: path[i-1].x*0.12 + point.x*0.76 + path[i+1].x*0.12,
            y: path[i-1].y*0.12 + point.y*0.76 + path[i+1].y*0.12 };
    });
    for (var pass = 0; pass < 2; ++pass) {
        var next = [out[0]];
        for (var k = 0; k < out.length - 1; ++k) {
            next.push(mix(out[k], out[k + 1], 0.25), mix(out[k], out[k + 1], 0.75));
        }
        next.push(out[out.length - 1]); out = next;
    }
    return out.length > 256 ? resample(out, 256) : out;
}
function nibFactors(path) {
    var raw = path.map(function(point, i) {
        var a = path[Math.max(0, i - 2)], b = path[Math.min(path.length - 1, i + 2)];
        // The Mac canvas is y-up; mirror its nib angle for Qt's y-down canvas.
        return Math.abs(Math.sin(Math.atan2(b.y - a.y, b.x - a.x) + Math.PI * 0.22));
    });
    return raw.map(function(value, i) {
        var sum = 0, count = 0;
        for (var j = Math.max(0, i - 3); j <= Math.min(raw.length - 1, i + 3); ++j) { sum += raw[j]; ++count; }
        return sum / count;
    });
}
// A visible pressure envelope even on an 80px gesture. The former 260px
// taper left short strokes almost uniform. Width also follows the nib angle
// and pools slightly through turns; all variation follows the actual path.
function penProfile(path, lifted) {
    if (!path.length) return [];
    var nib = nibFactors(path), total = length(path), walked = 0;
    if (total < 0.001) return path.map(function() { return 0.45; });
    return path.map(function(point, i) {
        if (i) walked += distance(path[i - 1], point);
        var s = walked / total;
        var entry = Math.pow(Math.min(1, (walked + 0.4) / Math.min(30, total * 0.26)), 0.72);
        var exit = lifted ? Math.pow(Math.min(1, (total - walked + 0.35) / Math.min(40, total * 0.34)), 0.85)
            : 1 - 0.32 * Math.pow(Math.max(0, (s - 0.72) / 0.28), 1.4);
        var a = path[Math.max(0, i - 3)], b = path[Math.min(path.length - 1, i + 3)];
        var ux = point.x - a.x, uy = point.y - a.y, vx = b.x - point.x, vy = b.y - point.y;
        var denominator = Math.hypot(ux,uy) * Math.hypot(vx,vy);
        var turn = denominator > 0.001 ? 1 - Math.max(-1, Math.min(1, (ux*vx+uy*vy)/denominator)) : 0;
        var body = (1.6 + 10.4 * Math.pow(nib[i], 0.72)) * (1 + Math.min(0.18, turn * 0.24));
        var tooth = 1 + 0.022 * Math.sin(walked * 0.21) + 0.012 * Math.sin(walked * 0.73);
        return Math.max(0.4, body * entry * exit * tooth);
    });
}
function liveWidths(path) { return penProfile(path, false); }
function penWidths(path) { return penProfile(path, true); }
function cleaned(path, direction) {
    if (!path.length) return [];
    var a = path[0], b = path[path.length - 1];
    var ideal = direction === "left" || direction === "right" ? [a, { x: b.x, y: a.y }] : [a, { x: a.x, y: b.y }];
    if (direction === "down_left") {
        ideal = [a, { x: a.x, y: b.y }, b];
        // Soften the corner as the native Ink pen does, retaining the bend.
        for (var pass = 0; pass < 3; ++pass) {
            var rounded = [ideal[0]];
            for (var i = 0; i < ideal.length - 1; ++i) rounded.push(mix(ideal[i],ideal[i+1],0.15),mix(ideal[i],ideal[i+1],0.85));
            rounded.push(ideal[ideal.length-1]); ideal = rounded;
        }
    }
    var hand = resample(path, 96), straight = resample(ideal, 96);
    return hand.map(function(point, i) { return mix(point, straight[i], 0.18); });
}
function ease(t) { t = Math.max(0, Math.min(1, t)); return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
function touchedCells(path) {
    if (!path.length) return {};
    var origin = path[0], touched = {};
    var samples = resample(path, Math.min(4096, Math.max(2, Math.ceil(length(path) / 4) + 1)));
    samples.forEach(function(p) {
        var c = Math.round((p.x - origin.x) / 20), r = Math.round((p.y - origin.y) / 20);
        touched[c + "," + r] = { c: c, r: r };
    });
    return touched;
}
function gridKey(touched, path) {
    if (!path.length) return "";
    var a = path[0], b = path[path.length - 1];
    return a.x + "," + a.y + ":" + Object.keys(touched).sort().join(";") + ":" + Math.round((b.x-a.x)/20) + "," + Math.round((b.y-a.y)/20);
}
function lattice(touched) {
    var nearest = {};
    Object.keys(touched).forEach(function(key) {
        var p = touched[key];
        for (var r = -4; r <= 4; ++r) for (var c = -4; c <= 4; ++c) {
            var squared = c*c + r*r;
            if (Math.sqrt(squared) * 20 >= 64 && squared !== 0) continue;
            var name = (p.c+c) + "," + (p.r+r);
            if (!nearest[name] || squared < nearest[name].squared) nearest[name] = { c: p.c+c, r: p.r+r, squared: squared };
        }
    });
    return Object.keys(nearest).map(function(key) {
        var cell = nearest[key], near = Math.max(0, 1 - Math.sqrt(cell.squared) * 20 / 64);
        cell.alpha = cell.squared === 0 ? 0.24 : 0.09 * Math.pow((Math.min(5, Math.floor(near * 6)) + 0.5) / 6, 1.5);
        return cell;
    });
}
