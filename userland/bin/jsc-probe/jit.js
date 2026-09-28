// JavaScriptCore's JIT on OrangeOS (docs/design/012 §4.5), run by jsc-probe
// with --useDollarVM=true. Hot functions must reach every JIT tier, whose
// code lives in the dual-mapped pool (patch 0008), and code compiled there
// must compute what the interpreter computes.
// Tiers compile on background threads, slowly under emulation, so keep the
// function hot for up to a minute.
function reaches(check) {
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline) {
        for (let i = 0; i < 100000; i++)
            if (check())
                return true;
    }
    return false;
}
const tiers = {
    baseline: reaches(function () { return $vm.baselineJITTrue(); }),
    dfg: reaches(function () { return $vm.dfgTrue(); }),
    ftl: reaches(function () { return $vm.ftlTrue(); }),
};

// A numeric kernel and an object-heavy one, hot enough for the top tier.
function mix(n) {
    let h = 0x811c9dc5;
    for (let i = 0; i < n; i++) {
        h ^= i & 0xff;
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h;
}
function points(n) {
    const list = [];
    for (let i = 0; i < n; i++)
        list.push({ x: i % 97, y: (i * 7) % 101 });
    let sum = 0;
    for (const p of list)
        sum += p.x * p.y;
    return sum;
}
let ok = true;
for (let round = 0; round < 40; round++) {
    ok = ok && mix(20000) === 276277093 && points(5000) === 11937389;
}
const all = tiers.baseline && tiers.dfg && tiers.ftl && ok;
print(`jsc-jit: ${all ? "PASS" : "FAIL"} baseline=${tiers.baseline} dfg=${tiers.dfg} ftl=${tiers.ftl} results=${ok}`);
