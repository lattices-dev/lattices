function buttonName(button) {
    var names = { "mouse:272": "Left", "mouse:273": "Right", "mouse:274": "Wheel click", "mouse:275": "Back", "mouse:276": "Forward", "mouse:277": "Forward", "mouse:278": "Back", "mouse:279": "Task button" };
    return names[button] || button;
}

function apply(previous, data) {
    var p = data.split("|");
    if (p.length !== 14 || p[0] !== "lattices-gesture" || p[1] !== "1") return null;
    var id = Number(p[2]), phase = p[3];
    if (!Number.isInteger(id) || id < 1 || ["start", "move", "pending", "commit", "cancel"].indexOf(phase) < 0) return null;
    if (!/^mouse:27[2-9]$/.test(p[4])) return null;
    var mx = Number(p[6]), my = Number(p[7]), x = Number(p[8]), y = Number(p[9]);
    if (![mx, my, x, y].every(function(n) { return Number.isFinite(n) && Math.abs(n) < 1000000; })) return null;
    if (["", "left", "right", "up", "down", "down_left"].indexOf(p[10]) < 0 || !/^[01]$/.test(p[11]) || !/^[01]$/.test(p[12])) return null;
    if (phase !== "start" && (!previous || previous.id !== id || ["pending", "commit", "cancel", "success", "failure", "noop"].indexOf(previous.phase) >= 0)) return null;
    var points = phase === "start" ? [] : previous.points.slice();
    var point = { x: x - mx, y: y - my };
    var last = points[points.length - 1];
    if (!last || Math.hypot(point.x - last.x, point.y - last.y) >= 1) points.push(point);
    if (points.length > 256) points = [points[0]].concat(points.slice(-255));
    return { id: id, phase: phase, button: p[4], buttonName: buttonName(p[4]), monitor: p[5], points: points,
        direction: p[10], ready: p[11] === "1", testing: p[12] === "1", label: p[13].slice(0, 100) };
}

function applyResult(previous, data) {
    var p = data.split("|");
    if (p.length !== 5 || p[0] !== "lattices-gesture-result" || p[1] !== "1") return null;
    if (!previous || previous.phase !== "pending" || Number(p[2]) !== previous.id) return null;
    if (["success", "failure", "noop"].indexOf(p[3]) < 0) return null;
    return Object.assign({}, previous, { phase: p[3], label: p[4].slice(0, 180) });
}
