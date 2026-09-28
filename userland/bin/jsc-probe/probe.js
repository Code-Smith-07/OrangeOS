// JavaScriptCore on OrangeOS (docs/design/012, W4): the language, the
// standard library, ICU-backed Intl, RegExp, promises and a sustained loop.
"use strict";
const results = [];
function check(condition, what) {
    if (!condition)
        throw new Error("FAIL " + what);
    results.push(what);
}

// Language.
class Fruit {
    #name;
    constructor(name) { this.#name = name; }
    get name() { return this.#name; }
    static compare(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0; }
}
const basket = ["orange", "apple", "mango"].map(n => new Fruit(n)).sort(Fruit.compare);
check(basket.map(f => f.name).join() === "apple,mango,orange", "classes and private fields");
function* count(limit) { for (let i = 1; i <= limit; i++) yield i; }
check([...count(5)].reduce((a, b) => a + b, 0) === 15, "generators and spread");
const { a, ...rest } = { a: 1, b: 2, c: 3 };
check(a === 1 && Object.keys(rest).join() === "b,c", "destructuring");
check((2n ** 100n).toString() === "1267650600228229401496703205376", "BigInt");
check(JSON.stringify(JSON.parse('{"x":[1,2,{"y":"z"}]}')) === '{"x":[1,2,{"y":"z"}]}', "JSON");
const map = new Map([[1, "one"]]), set = new Set([1, 1, 2]);
check(map.get(1) === "one" && set.size === 2, "Map and Set");
const typed = new Float64Array(1024).map((_, i) => i * 0.5);
check(typed.reduce((x, y) => x + y) === 261888, "typed arrays");
check(/(\d+)-(\d+)/.exec("range 12-345").slice(1).join() === "12,345", "RegExp");
check("aXbXc".replaceAll("X", "-") === "a-b-c" && "OrangeOS".at(-2) === "O", "string methods");

// ICU through Intl.
check(new Intl.NumberFormat("de-DE").format(1234567.891) === "1.234.567,891", "Intl.NumberFormat de-DE");
check(["b", "a", "C"].sort(new Intl.Collator("en").compare).join() === "a,b,C", "Intl.Collator");
check("İstanbul".toLocaleLowerCase("tr") === "istanbul", "locale case mapping");
const words = [...new Intl.Segmenter("en", { granularity: "word" }).segment("Orange OS runs JS")].filter(s => s.isWordLike);
check(words.length === 4, "Intl.Segmenter");
check(new Intl.DateTimeFormat("en-US", { timeZone: "UTC", year: "numeric" }).format(new Date(0)) === "1970", "Intl.DateTimeFormat");

// A sustained interpreted workload.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
const started = Date.now();
check(fib(24) === 46368, "recursion");
const big = Array.from({ length: 50000 }, (_, i) => (i * 7919) % 50000);
big.sort((x, y) => x - y);
check(big[0] === 0 && big[49999] === 49999, "sorting 50000 numbers");
const elapsed = Date.now() - started;

// Promises and async functions, run by the shell's microtask queue.
let settled = false;
(async () => {
    const value = await new Promise(resolve => resolve(42));
    check(value === 42, "async/await");
    settled = true;
    print("jsc-probe: PASS " + results.length + " checks (" + results.join(", ") + ") in " + elapsed + " ms");
})().catch(error => print("jsc-probe: FAIL " + error.message));
