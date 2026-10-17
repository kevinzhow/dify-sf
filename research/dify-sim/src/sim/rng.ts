// Deterministic PRNG (xoshiro128**) with named sub-streams, so that adding a consumer never perturbs another stream.
function hash32(s: string): number {
  let h = 2166136261 >>> 0
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 16777619) >>> 0
  }
  return h >>> 0
}
function splitmix32(a: number) {
  return () => {
    a = (a + 0x9e3779b9) | 0
    let t = a ^ (a >>> 16)
    t = Math.imul(t, 0x21f0aaad)
    t = t ^ (t >>> 15)
    t = Math.imul(t, 0x735a2d97)
    return (t = t ^ (t >>> 15)) >>> 0
  }
}
export class Rng {
  private s: Uint32Array
  constructor(seed: number, stream = '') {
    const sm = splitmix32((seed ^ hash32(stream)) | 0)
    this.s = new Uint32Array([sm(), sm(), sm(), sm()])
  }
  private rotl(x: number, k: number) {
    return ((x << k) | (x >>> (32 - k))) >>> 0
  }
  nextU32(): number {
    const s = this.s
    const result = Math.imul(this.rotl(Math.imul(s[1]!, 5) >>> 0, 7), 9) >>> 0
    const t = (s[1]! << 9) >>> 0
    s[2]! ^= s[0]!
    s[3]! ^= s[1]!
    s[1]! ^= s[2]!
    s[0]! ^= s[3]!
    s[2]! ^= t
    s[3] = this.rotl(s[3]!, 11)
    return result
  }
  /** uniform [0,1) */
  next(): number {
    return (this.nextU32() * 2 ** 21 + (this.nextU32() >>> 11)) / 2 ** 53
  }
  int(n: number): number {
    return Math.floor(this.next() * n)
  }
  range(a: number, b: number): number {
    return a + this.next() * (b - a)
  }
  chance(p: number): boolean {
    return this.next() < p
  }
  pick<T>(arr: readonly T[]): T {
    return arr[this.int(arr.length)]!
  }
  /** exponential with given mean */
  exp(mean: number): number {
    return -Math.log(1 - this.next()) * mean
  }
  /** approx normal(0,1) */
  normal(): number {
    let u = 0
    for (let i = 0; i < 6; i++) u += this.next()
    return (u - 3) * Math.SQRT2
  }
  shuffle<T>(a: T[]): T[] {
    for (let i = a.length - 1; i > 0; i--) {
      const j = this.int(i + 1)
      ;[a[i], a[j]] = [a[j]!, a[i]!]
    }
    return a
  }
  hex(n: number): string {
    let s = ''
    while (s.length < n) s += this.nextU32().toString(16).padStart(8, '0')
    return s.slice(0, n)
  }
  fork(stream: string): Rng {
    return new Rng(this.nextU32(), stream)
  }
}
