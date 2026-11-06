# Zig Style Guide

This is a portable style guide for Zig codebases. Rules are stated as bold one-liners with rationale and examples. All Zig API references target **Zig 0.17**.

The doc is rule-shaped, not framework-shaped: nothing here depends on a specific project, library, or runtime. Examples use generic placeholders (`Counter`, `Buffer`, `Sim`) or `std` references the reader can look up.

Cross-references between rules use the form `Rule X.Y`.

**Companion reading:** [`TIGER_STYLE.md`](TIGER_STYLE.md) — TigerBeetle's style guide. This document agrees with most of it and deliberately overrides a few points (notably file naming in Rule 1.1). Where the two disagree, this document wins for this codebase; the rationale is in the rule itself.

---

## Section 1 — File & Module Organization

### 1.1 — File naming: PascalCase for type files, snake_case for namespaces

A `.zig` file whose `pub` top level is a struct (the file behaves like a single type) is named `PascalCase.zig`. A file that exposes a namespace — free functions, enums, type aliases, or re-exports — is named `snake_case.zig`. The filename tells the reader, before they open it, whether `@import("Foo.zig")` gives back a type or a namespace.

```
Counter.zig    // top-level is `pub const Counter = struct { ... }` — the file IS the type
math.zig       // exposes `pub fn add`, `pub fn lerp`, `pub const Vec3` — a namespace
```

If a file's public API is dominated by one struct but also exposes a few struct-specific helpers, still use PascalCase — the file's identity is the type.

> Overrides Tiger Style's `snake_case` rule, but only for type-defining files. The trade: small loss of one consistent naming rule for a large gain in immediate file-shape signal.

---

### 1.2 — File-as-struct files must flatten; wrapping is a style violation

When a file's public surface is dominated by one `pub const X = struct { ... }` whose name matches the filename, the file MUST use the "file is a struct" idiom: the struct's fields and declarations live at file scope, and the file *is* the type. Wrapping the type inside the file is a style violation.

The wrapped form forces every consumer through `@import("Foo.zig").Foo` (or `mod.Foo.Foo` after a module-alias re-export). The flat form lets `@import("Foo.zig")` give back the type directly. The wrapper is dead syntax: an extra layer that carries no information beyond the filename.

```zig
// Wrong — Counter.zig wraps the type
pub const Counter = struct {
    count: u32 = 0,
    pub fn inc(self: *Counter) void { self.count += 1; }
};

// Right — Counter.zig IS the type
count: u32 = 0,

pub fn inc(self: *Counter) void { self.count += 1; }
```

**Carve-outs:**

- **Sibling helpers MAY remain alongside the file-scope fields** as `pub const` declarations — VTables, response wrappers, nested option types, error sets specific to this type. They live beside the type's fields, not nested inside an extra wrapper.
- **Multi-export modules are exempt.** Files with no single dominant type (`errors.zig`, `retry.zig`, `math.zig`) keep their snake_case name and remain namespaces, per Rule 1.1.
- **Generic type constructors are exempt.** Files whose public surface is `pub fn Owned(comptime T: type) type` or similar can't be flattened — there's no top-level struct, just a function that returns one. Naming still follows Rule 1.1 (PascalCase for type-returning constructors).

This rule pairs with Rule 1.3: a flattened file is re-exported as `pub const Counter = @import("Counter.zig");`, because `@import("Counter.zig")` *is* `Counter`. A wrapped file forces the awkward `@import("Counter.zig").Counter` re-export, which is exactly the friction this rule eliminates.

---

### 1.3 — `root.zig` is the module's re-export hub; nothing else

Every module directory has a `root.zig` whose sole job is to import the module's internal files and re-export the public surface. Permitted contents: imports of sibling files, `pub const` re-exports, and exactly one `test { @import("std").testing.refAllDecls(@This()); }` block at the end. No business logic, no helpers, no runtime state. Consumers import `root.zig` and never reach past it into specific files.

The `refAllDecls` test is non-negotiable: without it, tests in sibling files that aren't directly referenced from the binary entrypoint get silently skipped. Use the fully-qualified form (`@import("std").testing.refAllDecls`) so `root.zig` stays purely imports + re-exports + one test block.

**Re-export forms** — pick the one that gives consumers the shortest correct path:

```zig
// A flattened type file (Rule 1.2): the import IS the type; consumer writes `mod.Counter`.
pub const Counter = @import("Counter.zig");

// A namespace file holding a type that can't be a file-as-struct (e.g. a union);
// pull the type through, so the consumer writes `mod.Answer`, not `mod.answer.Answer`.
pub const Answer = @import("answer.zig").Answer;

// A namespace file (Rule 1.1 snake_case); consumer writes `mod.request.encode`.
pub const request = @import("request.zig");
```

`@import("Counter.zig").Counter` against a flattened file does not compile unless the file also declares `pub const Counter = @This();`, which is the redundant wrapper Rule 1.2 removes.

When a migration completes, delete the legacy `pub const` line from `root.zig`. Don't comment it out, don't keep it as an alias. `root.zig` is the *current* public surface, not a graveyard.

---

### 1.4 — Consolidate tiny cohesive files

A file split implies a separate concern. A file holding a single small function, a thin wrapper around another module's call, or a 3-line constant block should be folded into the related file that consumes it (or into `root.zig` if the whole module needs it). Don't keep a file alive just because it once held more.

Applies to namespace / utility files (snake_case). Does not override Rule 1.1 — prefer keeping PascalCase type files separate. Inline a type file only when the type is private to a single consumer and unlikely to grow.

> The opposite tension exists too: don't over-merge. A single file holding many comptime helpers, builders, or factories is correct *if* they share one concern. Identical concerns belong together; distinct concerns deserve files.

---

### 1.5 — Directory = feature, not kind

A directory groups files by *what they do for the app* (a domain or feature), not by *what shape the code has*. Asking "what does this dir do?" should give a domain answer ("audio mixing", "GPU rendering"), not a code-shape answer ("it has services", "it holds types"). When sub-features grow inside a feature dir, nest by sub-domain rather than promoting to top-level kind-dirs.

```
ok:    src/audio/      src/audio/effects/    src/audio/mixer/
not:   src/types/      src/helpers/          src/services/
```

**Smell:** a directory whose files all share a name suffix (`*Service.zig`, `*Manager.zig`, `*Helper.zig`) is almost always grouping by kind. Either move each file back to the feature it belongs to, or — if the suffix names a coherent runtime role (a contract / injection mechanism) — rename the directory after the role, not the suffix.

**Exception:** tiny feature dirs are fine. A directory with one or two `.zig` files plus `root.zig`, for a small but distinct concern, is correct. Rule 1.4 may later merge them up — separate question.

---

## Section 2 — Structs & Responsibility

### 2.1 — A struct is a compartment of responsibility, not a bag of fields

A struct exists because there is a single coherent thing it is *responsible for*. Its fields are the state required to fulfill that responsibility. If you can't name the responsibility in one short sentence, the struct is wrong — either too narrow (just data, no behavior) or too broad (god object, multiple responsibilities mashed together).

Exception: **value types** like `Vec3 { x, y, z }` or `Color { r, g, b, a }` whose responsibility *is* "represent this value". Pure-data structs are fine when they earn that role.

---

### 2.2 — Prefer methods on the responsible struct over free functions with wide parameter lists

When an operation conceptually belongs to a struct's responsibility, define it as a method on that struct. A free function whose first parameter is "the thing this is really about", and which takes several further parameters, should usually be a method.

```zig
// Method form — owns its state, narrow signature:
pub fn step(self: *Sim, dt: f32) void { ... }

// Free function with wide signature, no clear owner:
pub fn stepSim(
    entities: []Entity,
    physics: *Physics,
    collisions: *CollisionWorld,
    events: *EventBus,
    audio: *AudioEngine,
    renderer: *Renderer,
    dt: f32,
) void { ... }
```

The method form carries less cognitive load and makes the responsibility boundary visible. But don't fold a multi-input operation into one type just to make it a method — that creates a fake "ParamBag" struct that violates Rule 2.1.

---

### 2.3 — Free functions are for cross-type operations, not for behavior with an obvious home

A free function is the right shape when the operation is *between* multiple types — none would naturally claim it as a method. Consider:

```zig
pub fn eql(comptime T: type, a: []const T, b: []const T) bool
```

`std.mem.eql` is the canonical case: neither slice owns equality, the operation is symmetric. A free function whose extra parameters are really "configuration / flags for an operation that's about the first parameter" is a method in disguise.

Default to the method form; reach for the free function when the operation is genuinely symmetric across multiple inputs.

---

### 2.4 — Split a struct when distinct responsibilities emerge inside it

Once a struct's fields divide into clusters that don't talk to each other, or once its methods divide into groups that touch different fields, it has grown a second responsibility. Lift the sub-responsibility into its own struct and hold it as a field (composition) or pass it as a parameter. The leftover struct should still pass Rule 2.1 — its remaining responsibility nameable in one sentence.

**Symptoms that a struct is doing too much:**
- A subset of methods only touches a subset of fields, with little overlap between subsets.
- `init` takes a kitchen-sink of unrelated parameters.
- The struct's one-sentence responsibility requires "and" to describe it ("…manages X *and* handles Y *and* tracks Z").
- New features keep landing as "yet another field" with no natural place to attach them.
- The struct's name has drifted toward generic words: `Manager`, `Context`, `Engine`, `State`, `System`.

**How to split:**
- Find a method cluster that only touches a tight subset of fields. Those fields + those methods are a candidate sub-struct.
- Hold the new struct as a **field** (composition) if the original *uses* it as part of its own job. Pass it as a **parameter** if the original just *coordinates with* it.
- After the split, re-test: can each struct's responsibility be named in one sentence without "and"?

**What this rule does *not* mean:**
- **Don't split into struct + stateless helper struct.** If the extracted half has no fields of its own — just methods — those methods are free functions in a namespace (Rule 2.3), not methods on an empty type.
- **Don't split a coherent struct just because it's big.** A struct can have many fields and methods if they all serve one responsibility. Size is a hint to *look*, not a reason to *act*.
- **No hard numeric limits.** Comptime metaprogramming structs, builders, and serializers can have many fields legitimately. Judge by responsibility, not line count.

---

## Section 3 — State & Data Modeling

### 3.1 — Don't shadow real state with a `bool`

A `bool` that tracks the validity, presence, ownership, or cleanup-need of another field is redundant state that can drift. The other field already carries the same information — express it via the field's own type. Use `?T` for "may be absent", a tagged union for "one of these cases", or model the variant on the underlying type directly.

```zig
// Wrong: bool shadows whether `cache` is populated
cache: Cache = .{},
cache_valid: bool = false,

// Right: nullable cache, presence is "valid"
cache: ?Cache = null,
```

```zig
// Wrong: bool tracks whether `texture` needs to be freed on deinit
texture: Texture,
owns_texture: bool,

// Right: nullable texture, presence is "owned by us"
texture: ?Texture = null,
```

```zig
// Wrong: enum has a "none" case AND a bool to gate the value
mode: Mode,    // Mode = enum { off, foo, bar }
active: bool,  // mirrors `mode != .off`

// Right: drop the bool, check `mode != .off` directly
//        (or, if .off has different semantics from "no mode", model with a tagged union)
```

Any time you find yourself writing a `bool` *adjacent* to another field, ask whether the bool is something the field itself could carry. If yes, delete the bool — there is now one source of truth instead of two that can desync.

---

### 3.2 — Non-optional fields when always initialized

A field is `?T` only when its absence is a real state the program can be in. If every code path through `init` guarantees the field gets a value, the `?` is misleading historical caution — drop it, and simplify every access site (no `if (self.foo) |foo|` dance, no `orelse unreachable`).

```zig
// Wrong: optional that's always set after init
const Self = struct {
    allocator: Allocator,
    buffer: ?[]u8 = null,   // never actually null after init
};
pub fn init(allocator: Allocator) !Self {
    return .{
        .allocator = allocator,
        .buffer = try allocator.alloc(u8, 1024),  // always allocated
    };
}

// Right: drop the ?
const Self = struct {
    allocator: Allocator,
    buffer: []u8,
};
```

Optionality should reflect real uncertainty, not the order in which fields were added historically. If `init` doesn't always set a field, find out *why* — it may be a genuinely optional feature (in which case `?T` is right), or a missing init step (in which case the fix is in `init`, not in the type).

---

### 3.3 — Store data in the shape that matches your ownership role

The field's shape depends on who owns the data's lifetime:

- **Consumer / view / observer** (someone else owns it): match the API's shape. If their function returns `*T`, store `*T`. Don't dereference and copy out — copying creates a silent snapshot that can desync from the source, and the stored type no longer matches the source of truth.
- **Owner** (registry, store, container, factory): store whatever shape makes ownership unambiguous — typically a value (held in storage you control) or a pointer to your own allocation. The producing API may hand you a pointer for performance, but ownership transfers to you on insert. Copy on insert; you *are* the canonical source.

```zig
// Consumer / view: match the API's pointer shape
const ConsumerView = struct {
    thing: *Thing,                      // borrowed; lifetime owned by `lib`
    fn refresh(self: *ConsumerView, lib: *Lib) void {
        self.thing = lib.getThing();
    }
};

// Owner: copy on insert, hold what you own
const Registry = struct {
    items: std.ArrayList(Thing),        // values, owned by this struct
    fn insert(self: *Registry, allocator: Allocator, t: *const Thing) !void {
        try self.items.append(allocator, t.*);
    }
};
```

The question to ask before deciding the field's shape: *who owns the lifetime?* If something else owns it and you're observing → match the API's shape. If you own it → store it in whatever shape makes ownership clear and free-able by you.

**Failure modes the rule rules out:**
- A consumer silently copying a pointer-returned value into a field, then drifting out of sync with the source.
- An owner storing a pointer to data it claims to own but is actually borrowing from somewhere else.
- A struct whose ownership role is ambiguous — stores a pointer *and* a value of the same thing, or stores a pointer "for now" without a clear lifetime contract. Decide the role first, then the shape follows.

---

### 3.4 — Tagged unions over parallel optionals

When a struct has multiple `?T` fields where at most one is ever set, the type permits invalid states (multiple set, none set when one should be) and the constraint exists only in comments. A tagged union expresses "exactly one of these" in the type system, and forces every consumer to handle every case via exhaustive `switch`.

```zig
// Wrong: 3 optionals, only one ever set, constraint enforced only by comments
const Event = struct {
    key_press: ?KeyEvent = null,
    mouse_move: ?MouseEvent = null,
    quit: ?QuitEvent = null,
};

// Right: tagged union — exactly one case by construction
const Event = union(enum) {
    key_press: KeyEvent,
    mouse_move: MouseEvent,
    quit: QuitEvent,
};
```

A tagged union also makes adding a new case a compile error at every consumer that switches on it. Parallel optionals silently let new cases be ignored.

**When NOT to reach for a tagged union:** when the fields can genuinely coexist. An HTTP response can have an optional body *and* optional cache headers — both, neither, or one. Parallel optionals are correct then.

---

### 3.5 — Prefer `?T` over sentinel values

`?T` is the language-level mechanism for "no value". Don't use sentinel ints (`-1`, `0`, `std.math.maxInt(usize)`), empty strings, or empty slices to mean "absent" when the language already has the concept.

```zig
// Wrong: sentinel int
selected_index: i32,    // -1 means "no selection" (per a comment somewhere)

// Right: optional
selected_index: ?u32,   // null means "no selection" — visible in the type
```

Sentinels create three problems: the "absent" case is invisible to the reader, every consumer must remember to check the sentinel (and at least one will forget), and the valid range shrinks by one.

**Legitimate exceptions:**

- **Pointer optionals are already free.** `?*T` is the same size as `*T` in Zig because null fits in the zero-pointer slot — no overhead, no excuse to use a sentinel pointer.
- **Bit-packed values** where `?T` would balloon the layout and you've measured the impact.
- **Domain-defined sentinels with hardware / protocol meaning** (NaN, `~0` "all bits set", `0` as "invalid handle" in a C API). Name the constant (`const INVALID_HANDLE: u32 = 0;`) so the meaning is local and explicit, not folded into raw comparisons.

---

### 3.6 — Initialize at declaration when the default is meaningful; don't write a trivial `init`

A field whose natural starting value is the same in every `init` should declare that default inline. This serves two goals: defaults document the natural starting state, *and* it lets `init` shrink — or disappear entirely.

```zig
const Counter = struct {
    count: u32 = 0,
    name: []const u8 = "anonymous",
    state: State = .idle,
};

// Callers construct directly with struct literals — no init function needed:
const c1 = Counter{};
const c2 = Counter{ .name = "primary" };
```

**A trivial `init` is dead code.** If the function body is just `return .{};` or `return .{ .x = x };`, delete it — callers should use the struct literal directly. An `init` exists only when it *does* something: allocates, validates input, derives a field from another, takes ownership of a resource, performs work the caller couldn't do at the call site.

```zig
// Wrong: init adds nothing — caller could write the same literal
pub fn init(name: []const u8) Counter {
    return .{ .name = name };
}

// Right: no init — caller writes Counter{ .name = "x" } directly

// Right: init exists because it does real work
pub fn init(allocator: Allocator, capacity: usize) !Counter {
    return .{
        .buffer = try allocator.alloc(u8, capacity),
        .allocator = allocator,
    };
}
```

**When NOT to declare a default:**
- **No meaningful default exists.** `allocator: Allocator,` — leave un-defaulted so omitting it at the call site is a compile error.
- **The default would be misleading.** `buffer: []u8 = &.{},` for a field that *must* be a real allocation. Leave un-defaulted; a missing assignment is then a compile error.
- **Optional-with-`null` is suspect.** `foo: ?T = null,` is fine when null is the genuine starting state. If you're using null as "uninitialized yet", that's a Rule 3.2 violation.

**Carve-out for public library APIs:** removing a `pub fn init(...)` from a published package is a breaking change for downstream callers. In stable public APIs, keeping a thin `init` may be worth the indirection. The "delete trivial init" rule applies most cleanly inside private code.

---

## Section 4 — Error Handling & Cleanup

### 4.1 — `!void` + `errdefer` over scattered early returns

Extract multi-failure-path logic into a `fn tryX(...) !void` helper. Place `errdefer` immediately after each acquisition (allocation, file open, lock, etc.). One line of cleanup at the right place replaces N copies of cleanup before each `return`. The outer caller does `tryX(...) catch return` (or logs and returns).

**`errdefer` fires on the error return path only — not on success.** This is exactly what you want when the function transfers ownership of acquired resources to the caller on success.

```zig
// Wrong: scattered cleanup, easy to forget on a new failure path
pub fn doIt(allocator: Allocator) void {
    const a = allocator.alloc(u8, N) catch return;
    const b = allocator.alloc(u8, M) catch {
        allocator.free(a);              // remember to free a
        return;
    };
    const c = parse(b) catch {
        allocator.free(a);              // remember to free a
        allocator.free(b);              // remember to free b
        return;
    };
    use(a, b, c);
    allocator.free(b);
    allocator.free(a);
}

// Right: errdefer pairs each acquisition with cleanup at the acquisition point.
// On success, ownership of `a` and `b` transfers to the caller via the returned struct.
const Resources = struct {
    a: []u8,
    b: []u8,
};

fn tryAcquire(allocator: Allocator) !Resources {
    const a = try allocator.alloc(u8, N);
    errdefer allocator.free(a);

    const b = try allocator.alloc(u8, M);
    errdefer allocator.free(b);

    try validate(a, b);
    return .{ .a = a, .b = b };   // ownership transferred; errdefers fired only if a `try` above failed
}

pub fn doIt(allocator: Allocator) void {
    const r = tryAcquire(allocator) catch return;
    defer allocator.free(r.a);
    defer allocator.free(r.b);
    use(r.a, r.b);
}
```

Key points:
- **`errdefer` lives next to its acquisition.** Don't gather cleanup at the bottom of the function — that splits the lifetime in half and makes it easy to forget on new acquisition paths.
- **Use `defer` (not `errdefer`) when the resource is freed regardless of success or failure** — e.g. when the function uses the resource internally and never transfers ownership out.
- **`!void` (or `!T`) is the language's signal for "this can fail".** A function that calls any error-returning function should itself return `!T`, not catch internally and return `void`.
- **The outer caller is where policy lives** — log, retry, default, propagate. The inner helper just bubbles errors via `try`.

---

### 4.2 — Don't log AND propagate the same error

Decide one layer that handles the error and let the rest propagate. If you log here, you handle it (convert to default, abort, retry). If you propagate, the caller will decide — don't pre-log it. Double-logging produces noise without information; the symptom is the same error appearing three times in the log at increasing indentation.

```zig
// Wrong: log + propagate — caller likely logs it again
fn loadConfig(path: []const u8) !Config {
    return parseFile(path) catch |err| {
        log.warn("loadConfig failed: {}", .{err});
        return err;
    };
}

// Right: propagate silently
fn loadConfig(path: []const u8) !Config {
    return try parseFile(path);
}

// Right: log and decide at the boundary that has the policy
pub fn main() void {
    const cfg = loadConfig("...") catch |err| {
        log.err("config load failed: {} — using defaults", .{err});
        return defaults();
    };
}
```

---

### 4.3 — `catch {}` and `_ = x catch {}` are almost always wrong

Swallowing an error with `catch {}` claims "I inspected this and decided the failure is fine". That's rarely true. Either handle the error (log, default, retry) or propagate it (`try`). If you're truly certain it can't fail, write `catch unreachable` *and* add a one-line comment explaining **why** it can't fail — the invariant or guarantee, not just an assertion that it holds.

```zig
// Wrong: silently swallows real failure modes
_ = doSomething() catch {};

// Right: actually handle
doSomething() catch |err| log.warn("doSomething failed: {}", .{err});

// Right: invariant guarantees no failure, and the comment names that invariant
// buf is 32 bytes; max u64 decimal is 20 chars → bufPrint cannot overflow.
const slice = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
```

---

### 4.4 — `init` / `deinit` symmetry

Every successful `init` is paired with a `deinit`. `deinit` is infallible (`void` return). If `init` takes an `Allocator`, store it on `self` so `deinit` has no allocator parameter — pick one convention per project and apply it everywhere. After `deinit`, the struct is dead.

```zig
const Buffer = struct {
    data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Buffer {
        return .{
            .data = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.* = undefined;  // poison: catches use-after-deinit in debug builds, no-op in release
    }
};

// Caller pattern: init + defer deinit
var b = try Buffer.init(allocator, 1024);
defer b.deinit();
```

The `self.* = undefined` line is optional but useful — Zig's debug-mode safety turns subsequent reads into traps, so use-after-deinit fails loudly instead of returning stale bytes. In release builds it compiles to nothing.

---

### 4.5 — Asserts for programmer errors; errors for environment failures

A precondition violation that means "the code is wrong" is an `assert` (or `unreachable`). A failure that means "the environment is being uncooperative" (allocator OOM, file missing, parse failed, network down) is an `error`. Don't conflate them: returning an error for a logic bug encourages callers to recover from impossible states; asserting on real I/O makes prod crash on transient failure.

```zig
// Programmer error → assert
pub fn pop(self: *Stack) T {
    std.debug.assert(self.len > 0);     // caller must check before calling
    self.len -= 1;
    return self.data[self.len];
}

// Environment failure → error
pub fn loadConfig(allocator: Allocator, source: []const u8) !Config {
    return try parseConfig(allocator, source);
}
```

**Assertions must be cheap and side-effect-free.** Don't assert on a value you also need to use in production logic — release builds may compile the assert out, and the value won't be re-computed. `std.debug.assert(x.compute() > 0)` is a bug waiting to happen.

---

## Section 5 — Control Flow & Complexity

### 5.1 — Derive config at the point of use

Don't build a struct in one place to store values that are read exactly once somewhere else. Move the derivation inline into the function that consumes it. Each middleman struct doubles the boundaries (derive-site, field, read-site) for a single use, and is a place where the wrong value can be set, drift, or get confused.

The smell strikes hardest at **bootstrap singletons** — a setup phase that computes derived state, stores it on a globally accessible struct, and then has a single downstream consumer.

```zig
// Wrong: bootstrap derives values, stores them on a singleton,
//        consumers read once each. Three boundaries per value.
const Paths = struct {
    var instance: Paths = undefined;

    log_dir: []const u8,
    cache_dir: []const u8,

    pub fn bootstrap(env: Env, allocator: Allocator) !void {
        instance = .{
            .log_dir = try std.fs.path.join(allocator, &.{ env.home, "logs" }),
            .cache_dir = try std.fs.path.join(allocator, &.{ env.home, "cache" }),
        };
    }
};

fn logDir() []const u8 {
    return Paths.instance.log_dir;
}

// Right: derive at the point of use. Singleton gone, bootstrap gone,
//        the dependency (env) is now explicit at the call site.
fn logDir(env: Env, allocator: Allocator) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ env.home, "logs" });
}
```

The lighter variant is the same idea on a single struct: don't compute X at `init` and store it just so one method can read it later — let the method compute X itself from the inputs already on `self`.

**Exception:** when multiple consumers genuinely share the same derived value, the storage earns its keep. Derive at use site for one-shot consumers; pass the derived value as a parameter (or store it on a shared struct) when many call sites use the same value and re-computation would be wasteful. The rule rules out the *one-derivation-one-reader* middleman, not all caching or all config structs.

---

### 5.2 — Remove special cases when the general path handles them

Before adding a branch for an edge case, verify the general path already handles it (or can handle it cheaply with a small generalization). Two paths diverging for an edge case double the surface area of every future change, and the edge branch tends to rot once nobody remembers why it was added.

```zig
// Wrong: special-case for empty input that the general path handles
fn sumAll(xs: []const u32) u64 {
    if (xs.len == 0) return 0;        // unnecessary — the loop already returns 0
    var s: u64 = 0;
    for (xs) |x| s += x;
    return s;
}

// Right: general path covers the edge case (loop simply doesn't execute)
fn sumAll(xs: []const u32) u64 {
    var s: u64 = 0;
    for (xs) |x| s += x;
    return s;
}
```

**Test for "should this branch exist":** describe what the general path does on the edge-case input. If the answer is "the right thing, trivially", delete the branch. If the answer is "the wrong thing, or worse, UB", keep it.

**Inverse warning:** don't remove a special case if doing so makes the general path harder to read. Sometimes an early-return for `len == 0` *is* the simpler reading — it shortens the prose. The rule is about removing *dead* branches that the general path already handles, not about torturing the general path to eliminate every guard.

---

### 5.3 — Remove disabled modes when always-on is simpler

Feature toggles, no-op modes, and "off" branches add conditionals throughout the codebase. When a mode is no longer a real scenario — flag rolled out, alternate backend abandoned, debug path now permanent — delete the dead branches at every consumer. Don't leave silent `if (flag)` checks where `flag` never flips.

```zig
// Wrong: an "always on" flag still gating code
const enable_logging = true;
fn step() void {
    if (enable_logging) log.info("stepping", .{});
}

// Right: delete the flag, inline the body
fn step() void {
    log.info("stepping", .{});
}
```

Smells that point to a dead mode:
- A `const X = true;` (or `false`) that nothing ever flips.
- A function with multiple modes where one is `.noop` and never selected.
- An interface implementation whose body is empty/sentinel, and it's the only impl ever chosen.
- A `comptime` flag with one branch that compiles unused code "in case we need it".

If the disabled mode is a *real* possible future, leave a TODO that names it — **but delete the dead branches**. Re-add them when the scenario actually returns.

---

### 5.4 — Guard clauses over deep nesting

Handle invalid / edge-case inputs up front and return early. Deep `if {} else {}` pyramids bury the happy path; successive guard clauses at the top of a function flatten it.

```zig
// Wrong: nested pyramid
fn fetch(req: ?*Request) !Body {
    if (req) |r| {
        if (r.url.len > 0) {
            if (r.timeout_ms > 0) {
                return try get(r.url, r.timeout_ms);
            } else return error.InvalidTimeout;
        } else return error.MissingUrl;
    } else return error.NoRequest;
}

// Right: guards up front, happy path flat at the bottom
fn fetch(req: ?*Request) !Body {
    const r = req orelse return error.NoRequest;
    if (r.url.len == 0) return error.MissingUrl;
    if (r.timeout_ms == 0) return error.InvalidTimeout;
    return try get(r.url, r.timeout_ms);
}
```

---

### 5.5 — Don't pass a runtime flag to switch behavior inside a function

If a function takes a runtime `bool` (or enum) whose only role is to select between two unrelated code paths in the body, that's two functions wearing one hat. Split them. Every call site already knows which mode it wants — passing a flag hides that decision.

This rule is specifically about **runtime** flags. **Comptime branching is fine** — see Rule 5.6.

```zig
// Wrong: one function, two unrelated behaviors selected by a runtime flag
fn render(thing: *Thing, wireframe: bool) void {
    if (wireframe) { /* wireframe path */ }
    else          { /* solid path     */ }
}

// Right: two functions, each named for what it does
fn renderSolid(thing: *Thing) void { ... }
fn renderWireframe(thing: *Thing) void { ... }
```

**Exception:** when the flag selects a *value* used by mostly-shared code (e.g. a sort `ascending: bool` that flips one comparison), one function is fine. The test: how much of the body is gated by the flag? Majority → split. Sliver → keep.

---

### 5.6 — Comptime branching at the boundary; runtime code straight-line

When `comptime` decides which version of code to compile, push the branch to the boundary — specialize at the comptime level and let the runtime body be straight-line. Don't sprinkle `if (comptime cond)` throughout a function; it makes both compile-time intent and runtime flow harder to read.

```zig
// Wrong: comptime branches threaded through runtime code
fn render(comptime backend: Backend, scene: *Scene) void {
    setup();
    if (comptime backend == .vulkan) { /* vk path */ }
    else if (comptime backend == .metal) { /* metal path */ }
    cleanup();
}

// Right: dispatch at one boundary; each impl is flat
fn render(comptime backend: Backend, scene: *Scene) void {
    return switch (backend) {
        .vulkan => renderVulkan(scene),
        .metal  => renderMetal(scene),
    };
}
fn renderVulkan(scene: *Scene) void { ... }
fn renderMetal(scene: *Scene) void { ... }
```

`backend` is a `comptime` parameter, so the `switch` is resolved at compile time without needing an extra `comptime` keyword on the discriminant.

---

## Section 6 — Memory & Allocators

### 6.1 — Allocators are parameters, not globals

A function that allocates takes an `Allocator` parameter. Library code does not reach for a static or thread-local default; the caller decides which allocator backs the work. `std` follows this — `ArrayList(T).append` takes an allocator, parsers take one, etc.

```zig
// Wrong: function uses a hidden global
var global_gpa: std.heap.DebugAllocator(.{}) = .init;
pub fn loadConfig(path: []const u8) !Config {
    return try parseFile(global_gpa.allocator(), path);
}

// Right: caller passes allocator, sees the lifetime at the call site
pub fn loadConfig(allocator: Allocator, path: []const u8) !Config {
    return try parseFile(allocator, path);
}
```

This makes lifetime visible (the caller knows which allocator they passed), lets tests substitute `std.testing.allocator` for leak detection, and lets the same code run under arenas vs. debug allocators without modification.

**Exception:** an application's entrypoint (`main`, test runner) constructs one or a few allocators and passes them down. That's the one boundary — everywhere else, allocator is a parameter.

> Note for Zig 0.16: `std.heap.GeneralPurposeAllocator` was renamed to `std.heap.DebugAllocator`. The `.init` shorthand (`= .init`) works for both.

---

### 6.2 — Pick the allocator that matches the lifetime

Allocator choice matches the data's lifetime, not the convenience of the call site:

- **Arena (`std.heap.ArenaAllocator`)** for batch lifetimes (one request, one frame, one parse pass). `deinit` is O(1); you can ignore per-allocation lifetimes inside.
- **Debug / general-purpose allocator (`std.heap.DebugAllocator`)** for long-lived heterogeneous data with per-item lifetimes. Detects leaks and double-frees in debug builds.
- **Fixed buffer (`std.heap.FixedBufferAllocator`)** for short, bounded work with a known max size and no desire to syscall.
- **`std.testing.allocator`** in tests — fails the test on leak.
- **`std.heap.smp_allocator`** as a parent allocator for arenas in production, when `page_allocator` is too heavyweight for small/frequent allocations.

```zig
// One request worth of allocations, all freed at once
fn handleRequest(req: Request) !Response {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try parseBody(a, req.body);
    const route  = try matchRoute(a, parsed);
    return try buildResponse(a, route);
}
```

If you find yourself tracking many small frees with the same lifetime, you wanted an arena.

---

### 6.3 — Store the allocator on `self` when the struct allocates

Receive the allocator as a parameter in `init` (per Rule 6.1), then store it on `self` so `deinit` has no allocator parameter. The struct owns its allocations end-to-end; callers don't track which allocator was used.

```zig
const Buffer = struct {
    data: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !Buffer {
        return .{
            .data = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};
```

Cost: `@sizeOf(Allocator)` per instance (a vtable pointer + state pointer). If many small instances exist and the size matters, pass the allocator into each method instead. For the common case (a handful of long-lived structs), store it.

---

### 6.4 — Free at the layer that allocates; ownership transfer is explicit

If a function allocates and returns the allocation to the caller, the caller frees — and the function's name should make that clear (`dupe`, `…Alloc`, return docs). If a function allocates and uses internally, it frees via `defer` / `errdefer`.

Ownership transfer across an API boundary must be obvious from the signature.

```zig
// Wrong: borrows a slice indefinitely; caller can't see the lifetime contract
const Logger = struct {
    name: []const u8,                     // borrowed? owned? unclear
    pub fn init(name: []const u8) Logger { return .{ .name = name }; }
};

// Right: take ownership via dupe — lifetime is now self-contained
const Logger = struct {
    name: []const u8,
    allocator: Allocator,
    pub fn init(allocator: Allocator, name: []const u8) !Logger {
        return .{
            .name = try allocator.dupe(u8, name),
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Logger) void {
        self.allocator.free(self.name);
    }
};
```

`Allocator.dupe(T, src)` is the canonical "copy a slice into my allocator" call. If you genuinely want to borrow (caller guarantees lifetime), document the contract in a comment on the field. The default is to own.

---

### 6.5 — Comptime-known sizes go to the stack or static memory

If a buffer's size is known at compile time and bounded by something small, use a stack array or static variable. Don't reach for the heap because "alloc is the obvious tool". Stack is free; heap costs a possible syscall, a `free` obligation, and an error path.

```zig
// Wrong: small bounded buffer pulled from the heap
const buf = try allocator.alloc(u8, 32);
defer allocator.free(buf);
const written = std.fmt.bufPrint(buf, "{d}", .{x}) catch unreachable;
_ = written;

// Right: stack array, no allocator needed at all
var buf: [32]u8 = undefined;
// `bufPrint` returns the formatted slice (a view into `buf`), not a length.
// buf is 32 bytes; max u64 decimal is 20 chars → cannot overflow.
const out = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
_ = out;
```

Threshold: is the size known and bounded, and is the function not deep in a recursive call chain? Stack it. Reach for the heap when the size is data-dependent or the lifetime crosses the stack frame.

---

### 6.6 — Prefer fixed-size data structures when bounded

When a collection's max size is known and reasonable, use `[N]T` or `std.ArrayList(T).initBuffer` over growable containers backed by `Allocator`. Growable containers hide allocation behavior — one `append` can trigger a realloc, copy, and free. Fixed-size has predictable cost, no growth allocation, and no hidden failure mode.

```zig
// Wrong: a list known to hold at most 8 items, growing on the heap
var enabled: std.ArrayList(Feature) = .empty;
defer enabled.deinit(allocator);
try enabled.append(allocator, .foo);

// Right: bounded by a stack buffer; no allocator, no hidden growth
var storage: [8]Feature = undefined;
var enabled: std.ArrayList(Feature) = .initBuffer(&storage);
try enabled.appendBounded(.foo);   // error{OutOfMemory} if full
```

`std.ArrayList(T).initBuffer` (Zig 0.16) backs the list with a caller-provided fixed buffer. `appendBounded` returns an error instead of growing. This is the modern replacement for `std.BoundedArray`, which was removed.

Reach for the heap-growable form when the size is genuinely unbounded by input shape. For known small bounds, prefer fixed storage.

---
