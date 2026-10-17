export default {
  python: [
    ['dify_default', `
def main(arg1: str, arg2: str):
    return {
        "result": arg1 + arg2,
    }
`],
    ['keywords_numbers', `import json
from typing import Any
@decorator
class Foo(Base):
    def __init__(self, x=0x1F, y=-3.5e10, z=10j, w=42L):
        self.x = [x, y]; print(None, True, False)
        _ = lambda a: a ** 2  # trailing comment
# full line comment
        return not x and y or z
`],
    ['strings', `a = 'single' + "double"
b = 'esc \\' quote' + "esc \\" quote"
c = f'hello {name!r} and {value:>10} {x=}'
d = f"dbl {obj.attr} \\n"
e = '''doc
string with ' and '' inside
end'''
f = """dbl
doc"""
g = 'unterminated
h = "line \\
continued"
i = ''
j = ""
`],
    ['unicode_and_misc', `# 中文注释
s = "中文字符串"  # 注释
变量 = 1
x = {'k': [1, 2, (3, 4)]}
y = x['k'][2]
z = a if b else c
async def f():
    await g()
match cmd:
    case _:
        pass
`],
    ['edge_cases', `@app.route("/x")
def f(a=.5, b=1e-3, c=0xFFL, d=-7):
    s = f"{a['k']} {b} {{literal}} {c:{d}}"
    t = 'abc\\
def'
    '''starts here
    and ends ''' ; x = 1
    u = "tab\there" + r'raw\d' + b'bytes'
    return [i for i in range(3)]  # c
`],
  ],
  javascript: [
    ['dify_default', `
function main({arg1, arg2}) {
    return {
        result: arg1 + arg2
    }
}
`],
    ['keywords_operators', `const a = 1, b = 0x1F, c = 0o17, d = 0b101, e = 1.5e-3, f = 10n;
let x = a === b ? c : d; x += 2; x **= 3;
if (!x && y || z ?? w) { return typeof x; }
class Foo extends Bar { constructor() { super(); this.#priv = null; } }
async function* gen() { yield await import('./m.js'); }
const arrow = (p) => p >= 1 && p <= 2;
const MyType = undefined; let s = Symbol();
export default { a, b };
`],
    ['strings_regex_comments', `const s1 = 'single \\' esc', s2 = "double \\x41 \\u0041 \\q";
const t = \`template \${a + \`nested \${b}\`} end\`;
const u = \`multi
line \${ {k: 1}.k } tail\`;
const r = /ab+c[^/\\]]{2,3}(?:x|y)\\d/gi.test(s);
const div = a / b / c;
// line comment
/* block
   comment */ const after = 1;
/** jsdoc
 * @param {string} x
 */
const bad = "unterminated
const bad2 = 'unterminated2
`],
    ['edge_cases', `const re = /[a-z\\]]+\\/x/g, re2 = /(?:a|b){1,3}[^-]/;
if (a < b && c > d) { x = a<b>c; }
const t = \`\${ {a: 1}.a } and \${ \`in\${ner}\` }\`;
class P { #x = 1; get x() { return this.#x !== 2; } }
/* a */ b /* c
still comment */ const after = [1, 2];
let s = "a" + 'b' + \`c\`; // done
`],
  ],
  json: [
    ['object', `{
  "type": "object",
  "properties": {
    "id": { "type": "string" },
    "n": 12.5e3,
    "neg": -4,
    "ok": true,
    "no": false,
    "nil": null,
    "arr": ["a", 1, {"k": "v"}, [true]]
  },
  "required": ["id", "name"]
}`],
    ['comments_errors', `// line comment
{
  /* block
     comment */ "a": "multi
line string",
  "b": "esc \\" \\u0041",
  "c": unknown, "d": 01, "e": 1.,
  "f": -
}`],
    ['nesting_quirk', `{
  "a": {"b": {
  "c": "d"
  }},
  "list": [
    "x",
    {"k": [1, {"z": null}]}
  ],
  "after": "v"
}`],
  ],
};
