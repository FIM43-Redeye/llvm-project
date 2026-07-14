(amdgpu-memmodel)=

# AMDGPU Memory Model

```{contents}
:local: true
```

## Introduction

The {ref}`LLVM memory model<memmodel>` provides broad guarantees that are
sufficient to implement inter-thread communication via memory. But in most
communication patterns, not all memory accesses performed by a thread need to be
exposed to other threads. Even when they do need to be exposed, not all threads
may need to observe these memory accesses. This document describes the *AMDGPU
memory model* that allows the user to control how the side-effects of memory
accesses are propagated across threads. The programmer expresses this using
**new intrinsics, types and metadata** as described below, and the
implementation can then choose a more efficient mechanism to complete them, such
as the cache policy bits in an AMDGPU device.

The AMDGPU memory model allows executions that are not allowed by the LLVM
memory model. At the same time, a simple mapping can be used to implement these
new intrinsics, types and metadata using operations defined in the default LLVM
memory model. Thus, **there exists a safe-by-default implementation** that produces
executions that are valid in both models.

## Terminology

Memory Accesses

: Operations that read or write locations in memory are termed as *memory
  accesses*. Typical examples are `load`, `store` and atomic instructions,
  as well as many intrinsics.

Synchronizing Operations

: Synchronizing operations control how the side-effects of memory accesses are
  propagated in the system. Typical examples are atomic operations (including
  fences) with at least `release` or `acquire` ordering.

(amdgpu-scopes)=

## Scopes

A *scope* is an abstract description of sets of memory accesses and
synchronizing operations in a multi-threaded execution environment. Each such
set is called an *instance* of that scope, or a *scope instance* for short.

- Each memory access or synchronizing operation belongs to at most one
  instance of every scope defined by the target.
- When an operation `X` specifies a scope `S`, it indicates the instance of
  `S` that contains `X`. This scope instance is also termed as *X's instance
  of scope S*, or just *X's scope instance* when `S` is implied by the
  context.
- When an operation does not specify a scope, it indicates the *system*
  scope defined below.

### LLVM scopes

The LLVM Language Reference defines the following {ref}`scopes<syncscope>`:

*system scope* (empty string "")

: There exists a single instance of this scope that contains the memory accesses
  and synchronizing operations performed by all threads.

"singlethread" scope

: Each thread corresponds to a "singlethread" scope instance that contains the
  memory accesses and synchronizing operations performed by that thread.

### AMDGPU scopes

The AMDGPU target defines the following LLVM scopes:

- *system scope* (same as LLVM)
- "agent" scope
- "cluster" scope
- "workgroup" scope
- "wavefront" scope
- "singlethread" scope (same as LLVM)

These are arranged from largest scope (*system scope*) to smallest scope
("singlethread").

- Every scope `S1` other than *system scope* is a *subscope* of the scopes
  above it in this linear arrangement.
- If `S1` is a subscope of `S2`, then an instance `I1` of `S1` is a
  subset of some instance `I2` of `S2`, and `I1` is said to be a
  *subscope instance* of `I2`.
- If two scope instances `I1` and `I2` intersect, then their intersection is
  the smaller of `I1` and `I2`.

#### Containment

Every operation *belongs to* an instance of a specific scope:

- Operations executed by each thread (loads, stores, atomics, fences) *belong
  to* the corresponding "singlethread" scope instance.
- DMA operations *initiated by* each thread *belong to* an instance of the
  corresponding {ref}`DMA scope<amdgpu-dma-scopes>`.

Every operation is *contained* in the scope instance `I1` that it *belongs
to*, as well as every scope instance `I2` such that `I1` is a *subscope
instance* of `I2`.

This affects how operations are related in *inclusive scopes* when determining
availability and visibility. For example, DMA operations require
{ref}`explicit availability and visibility<amdgpu-dma-visibility>`
operations at scopes below the corresponding DMA scope.

#### Inclusive Scopes

Two operations `X` and `Y` are said to have *inclusive
scopes* if the scope instance of each operation contains the other operation. In
that case, the *common scope instance* `S'` of `X` and `Y` is the
intersection of their scope instances. The scope corresponding to `S'` is also
termed as the *common scope* of `X` and `Y`.

(amdgpu-scope-type)=

#### Scope Argument

Several intrinsics accept a `scope` argument that identifies a scope
instance. The scope argument can be passed in one of two ways:

- `target("amdgcn.scope")` — A target extension type whose values are
  opaque scope identifiers. Values of this type can only be produced by the
  scope intrinsics listed below.
- `metadata` **(deprecated)** — A metadata value containing either a scope
  name string (e.g., `metadata !"workgroup"`) or a `ValueAsMetadata`
  wrapping a scope value.

New intrinsics accept only `target("amdgcn.scope")`. Deprecated intrinsics
that accept `metadata` are documented alongside their replacements.

The `target("amdgcn.scope")` type is opaque and token-like: a scope value may
only flow directly from a producer intrinsic to a consumer intrinsic within a
single function. It cannot be loaded from or stored to memory, passed as a
function argument, returned from a function, or used in `phi` or `select`
instructions.

The following intrinsics return the AMDGPU LLVM scopes:

```llvm
target("amdgcn.scope") @llvm.amdgcn.scope.system()
target("amdgcn.scope") @llvm.amdgcn.scope.agent()
target("amdgcn.scope") @llvm.amdgcn.scope.cluster()
target("amdgcn.scope") @llvm.amdgcn.scope.workgroup()
target("amdgcn.scope") @llvm.amdgcn.scope.wavefront()
target("amdgcn.scope") @llvm.amdgcn.scope.singlethread()
```

Additional scope intrinsics for {ref}`DMA scopes<amdgpu-dma-scopes>`:

```llvm
target("amdgcn.scope") @llvm.amdgcn.scope.lds.dma()
target("amdgcn.scope") @llvm.amdgcn.scope.tensor.dma()
```

An example:

```llvm
%wg = call target("amdgcn.scope") @llvm.amdgcn.scope.workgroup()
call void @llvm.amdgcn.make.available(target("amdgcn.scope") %wg)
%dma = call target("amdgcn.scope") @llvm.amdgcn.scope.lds.dma()
call void @llvm.amdgcn.make.available(target("amdgcn.scope") %dma)
```

## Availability and Visibility

The AMDGPU memory model is built on top of the {ref}`happens-before<memmodel>`
order defined by the LLVM memory model. But when one of the new intrinsics or
metadata is used, **happens-before by itself is not sufficient** to describe its
observable effects. Instead, the AMDGPU model uses *availability* and
*visibility* to describe how the side-effects of these operations propagate to
other threads.

Availability determines how *far* the side-effects of a write have been
forwarded in the system relative to that write. Visibility determines how
*close* the side-effects of the same write have reached relative to an observer
operation (typically a read).

The AMDGPU memory model *does not change the structure of happens-before*, but
changes the rules that determine how operations may observe the side-effects of
other operations that *happen-before* them.

Consider a write `W` that `happens-before` a read `R` to the same address:

- `R` can potentially observe the side-effects of `W` **only if W is
  visible** to `R`.
- `W` can potentially be visible to `R` **only if W is first made
  available** to `R`.

The instructions used in the default LLVM memory model automatically satisfy
these necessary conditions, and hence they can be explained using the rules from
either memory model. But the new intrinsics and metadata *opt out* of the LLVM
memory model, and can only be explained using the AMDGPU memory model.

(amdgpu-store-available)=

### store-available

```llvm
@llvm.amdgcn.global.store.available.b128(ptr, value, target("amdgcn.scope"))
@llvm.amdgcn.av.global.store.b128(ptr, value, scope)    ; (deprecated)
store atomic [syncscope("<target-scope>")]
atomicrmw    [syncscope("<target-scope>")]
cmpxchg      [syncscope("<target-scope>")]
```

The `@llvm.amdgcn.global.store.available.b128` intrinsic performs a non-atomic
*store-available* operation on `ptr` with scope `scope` (see
{ref}`amdgpu-scope-type`).

:::{note}
The deprecated `@llvm.amdgcn.av.global.store.b128` intrinsic accepts scope
as a metadata argument. New code should use
`@llvm.amdgcn.global.store.available.b128` instead.
:::

An atomic operation that results in a store operation is a *store-available*
operation with scope `syncscope`.

(amdgpu-load-visible)=

### load-visible

```llvm
@llvm.amdgcn.global.load.visible.b128(ptr, target("amdgcn.scope"))
@llvm.amdgcn.av.global.load.b128(ptr, scope)             ; (deprecated)
load atomic  [syncscope("<target-scope>")]
atomicrmw    [syncscope("<target-scope>")]
cmpxchg      [syncscope("<target-scope>")]
```

The `@llvm.amdgcn.global.load.visible.b128` intrinsic performs a non-atomic
*load-visible* operation on `ptr` with scope `scope` (see
{ref}`amdgpu-scope-type`).

:::{note}
The deprecated `@llvm.amdgcn.av.global.load.b128` intrinsic accepts scope
as a metadata argument. New code should use
`@llvm.amdgcn.global.load.visible.b128` instead.
:::

An atomic operation that results in a read operation is a *load-visible*
operation with scope `syncscope`.

:::{note}
Metadata cannot be used to model this using ordinary load/store operations,
because the scope is necessary for correctness. In a hypothetical operation
like this:

```llvm
store ptr, data, !mmra !{!"amdgcn-av", !"workgroup"}
```

If the metadata is dropped or ignored, there is no guarantee that the store
will become available at the intended scope. In implementation terms, the
store may be completed at a nearer cache than the one required for that
scope. A corresponding *load-visible* that does not access the same near
cache will fail to observe this store.
:::

### MakeAvailable and MakeVisible

#### make.available and make.visible

```llvm
@llvm.amdgcn.make.available(target("amdgcn.scope"))
@llvm.amdgcn.make.visible(target("amdgcn.scope"))
```

`@llvm.amdgcn.make.available` is a `MakeAvailable` operation at scope
`scope` (see {ref}`amdgpu-scope-type`). It makes all preceding writes
available at that scope.

`@llvm.amdgcn.make.visible` is a `MakeVisible` operation at scope
`scope` (see {ref}`amdgpu-scope-type`). It makes writes that are
available at that scope visible to subsequent reads.

#### make.ptr.available and make.ptr.visible

```llvm
@llvm.amdgcn.make.ptr.available(ptr, target("amdgcn.scope"))
@llvm.amdgcn.make.ptr.visible(ptr, target("amdgcn.scope"))
```

`@llvm.amdgcn.make.ptr.available` is an *availability operation* on
preceding writes to `ptr` at scope `scope` (see {ref}`amdgpu-scope-type`).

`@llvm.amdgcn.make.ptr.visible` is a *visibility operation* on `ptr` at
scope `scope` (see {ref}`amdgpu-scope-type`). It makes writes to `ptr`
that are available at that scope visible to subsequent reads.

(amdgpu-av-metadata)=

#### AV Metadata

```llvm
!mmra !{!"amdgcn-av", !"none"}
```

The presence of this metadata removes the ability of synchronizing operations to
establish availability and visibility, and essentially creates *non-av* synchronizing
operations.

For a synchronizing operation which itself accesses memory (e.g., `store atomic
release` or `load atomic acquire`), the metadata does not affect the
availability or the visibility of the access performed by the operation itself.
It only affects the synchronization of other memory accesses.

#### Synchronizing Operations

```llvm
store atomic [syncscope("<target-scope>")] <ordering> [, !mmra !{!"amdgcn-av", !"none"}]
load atomic  [syncscope("<target-scope>")] <ordering> [, !mmra !{!"amdgcn-av", !"none"}]
atomicrmw    [syncscope("<target-scope>")] <ordering> [, !mmra !{!"amdgcn-av", !"none"}]
cmpxchg      [syncscope("<target-scope>")] <ordering> [, !mmra !{!"amdgcn-av", !"none"}]
fence        [syncscope("<target-scope>")] <ordering> [, !mmra !{!"amdgcn-av", !"none"}]
```

A synchronizing operation with at least `release` ordering is a
`MakeAvailable` operation with scope `syncscope`, if it is not marked as
`!{!"amdgcn-av", !"none"}`.

A synchronizing operation with at least `acquire` ordering is a
`MakeVisible` operation with scope `syncscope`, if it is not marked as
`!{!"amdgcn-av", !"none"}`.

```llvm
; This includes the following operations:
; - The atomic store at "agent" scope,
; - A store-available operation at "agent" scope on `ptr`,
; - A `MakeAvailable` operation at "agent" scope that affects previous memory accesses.
store atomic syncscope("agent") release ptr

; This includes the following operations:
; - The atomic store at "agent" scope,
; - A store-available operation at "agent" scope on `ptr`.
; Notably, it does not include a `MakeAvailable` operation on other memory accesses.
store atomic syncscope("agent") release ptr, !mmra !{!"amdgcn-av", !"none"}
```

## Ordering

:::{note}
**TODO:** These ordering operations affect all address spaces. We need to
eventually make that a parameter similar to the storage class parameter on
operations and orders in Vulkan.
:::

(amdgpu-dma-ordering)=

### DMA Ordering

A DMA operation `D` *initiated* by an instruction `X` is *completed-at* an
operation `Y` if:

- `D` is a synchronous operation and `X` is *program-ordered* before
  `Y`, or,
- `D` is an asynchronous operation and a completion mechanism such as an
  {ref}`asyncmark<amdgpu-asyncmark-completed-at>` or a barrier is used to
  establish that `D` is *completed-at* `Y`.

#### DMA in `synchronizes-with`

If a DMA operation `D` is *completed-at* a `wait.asyncmark()` operation
`Y`, then the *tail release* `Rel` inside `D` *synchronizes-with* `Y`.

If a DMA operation `D` is *completed-at* a control synchronization operation
`X` (such as a `barrier.wait`) then the *tail release* operation `Rel` in
`D` *synchronizes-with* an *acquire* operation `Acq` if:

- `X` is *program-ordered* before `Acq`, and
- `D` is included in the scope instance of `Acq`.

The internal operations of `D` are ordered simply by *dma-program-order*: the
entry is ordered before the reads; the reads are ordered before the writes they
feed; and the writes are ordered before the tail *release*. Thus, a DMA
operation is modeled as a thread terminated by its *tail release*.

#### DMA in `happens-before`

An operation `X` inside a DMA operation `D` *happens-before* an operation
`Y` if:

- `X` is *dma-program-ordered* before the *tail release* operation `Rel` in
  `D`, and,
- `Rel` *synchronizes-with* an *acquire* operation `Acq`, and,
- `Acq` is *program-ordered* before `Y`, or `Y` is `Acq` itself.

:::{attention}
This addition to *happens-before* is verbose and likely to cause a minor
confusion in the reader's mind. The LLVM version simply says "transitive
closure of the union of *synchronize-with* and *program-ordered*". With our
verbose text, the reader is left wondering if there is a structural
difference between LLVM's simple closure and how *dma-program-order* passes
through *synchronize-with* to chain with *program-order*.
:::

(amdgpu-amdgpu-happens-before)=

### `amdgpu-happens-before`

An operation `A` *amdgpu-happens-before* an operation `B` if:

- `A` *happens-before* `B`, or,
- `A` *initiates* a DMA operation `B`, or,
- There is an operation `X` such that:

  - `A` *happens-before* `X`, and,
  - `X` *initiates* a DMA operation `B`.

### Availability Operation

An operation `X` is an *availability operation* on a write `W` if one of the
following holds:

- `X` is `W` itself, and `W` is a *store-available* operation, or,

- `X` is a `MakeAvailable` operation that follows `W` in program order,
  or,

- `X` is a `MakeAvailable` operation whose scope instance includes `W`,
  and there is an availability operation `Z` on `W` such that:

  - `Z` *amdgpu-happens-before* `X`, and,
  - `Z`'s scope instance includes `X`.

Then `X` makes `W` available in its own scope instance `S` and every
subscope instance of `S` that also includes `W`.

### Visibility Operation

An operation `Y` is a *visibility operation* on a write `W` if `Y` is a
*load-visible* operation to the same address, or a `MakeVisible` operation,
and one of the following holds:

- There exists an *availability* operation `X` on write `W` such that:

  - `X` *amdgpu-happens-before* `Y`, and,
  - `X` and `Y` specify inclusive scopes.

  Then `Y` makes `W` visible in the common scope instance `S` of `X` and
  `Y`, and every subscope instance of `S` that includes `Y`.

- There exists a *visibility* operation `X` on write `W` such that:

  - `X` *amdgpu-happens-before* `Y`, and,
  - `X` makes `W` visible in a scope instance `S1` that includes `Y`, and,
  - `X` is included in the scope instance `S2` of `Y`.

  Then `Y` makes `W` visible in the intersection `S` of `S1` and `S2`,
  and every subscope instance of `S` that includes `Y`.

(amdgpu-location-order)=

### Location Order

A write `W` is *location-ordered* before an access `Y` to the same address
if `W` is program-ordered before `Y`.

A write `W` is *location-ordered* before a write `W1` to the same address if
there exists an availability operation `Z` on `W` such that:

- `Z` *amdgpu-happens-before* `W1`, and,
- `W1` is included in `Z`'s scope instance.

A write `W` is *location-ordered* before a read `R` to the same address if
there exists a visibility operation `Z` on write `W` such that:

- `Z` is `R` itself, or,
- `Z` precedes `R` in program order.

The AMDGPU memory model overrides the definition of each byte in the
{ref}`LLVM memory model<memmodel>` as follows.

Every (defined) read operation `R` reads a series of bytes written by
(defined) write operations. Each initialized global is assumed to have an
initial *system scoped* atomic write operation that is *location-ordered* before
any other read or write to that same location.

For each byte of a read `R`, `R` may see any write to the same byte, except:

- If a write `W1` is *location-ordered* before a write `W2`, and `W2` is
  *location-ordered* before a read `R`, then `R` may not see `W1`.
- If a read `R` *amdgpu-happens-before* a write `W3`, then `R` may not see
  `W3`.

The value returned by `R` is then defined as follows:

- If no write is *location-ordered* before a read `R`, then `R` returns
  `undef`.
- Otherwise if the set consisting of `R` and all writes that `R` may see
  contains only atomic operations with inclusive scopes, then `R` returns the
  value written by one of those writes.
- Otherwise, if `R` may see some write that is not *location-ordered* before
  `R`, then `R` returns `undef`.
- Otherwise, if `R` may see exactly one write `W`, then `R` returns the
  value written by `W`.
- Otherwise, `R` returns `undef`.

## Properties

:::{tip}
This section is informational.
:::

The following properties follow from the definitions above:

1. **amdgpu-happens-before is necessary for location-order.** A write `W` is
   *location-ordered* before a read `R` only if `W`
   *amdgpu-happens-before* `R`.
   This follows from the definition of availability and visibility operations,
   which always require an *amdgpu-happens-before* link with the preceding
   operation in the chain.
2. **A write cannot be made available in a scope that does not contain it.** The
   definition of an availability operation `X` requires that `X`'s scope
   instance includes `W` as a precondition. Since every scope instance that
   includes `X` also includes `W`, availability cannot reach a scope
   instance that excludes `W`. In other words, availability can only "expand
   outwards" into progressively larger scopes.
3. **Visibility is bounded by availability.** When a write is available in a
   scope instance, it can be made visible in that scope instance by a visibility
   operation with the corresponding scope. Subsequent `MakeVisible` operations
   make that write visible into narrower scope instances towards the observer.
4. **A write can be made visible in a scope instance that does not contain it.**
   The definition of a *visibility operation* anchors scope instances to the
   observer (`Y`), not to the original write. The only precondition is that the
   write must already be visible or available in the scope instance of the
   visibility operation.
5. **Availability and visibility chains.** For a write `W` to be visible to a
   read `R` anywhere in the system, the sufficient condition is a chain of
   happens-before edges that include availability and visibility operations with
   inclusive scopes. It is not necessary that `W` and `R` themselves have
   inclusive scopes. Each link in the availability and visibility definitions
   only checks the immediate predecessor, so intermediate operations can bridge
   scope gaps that the endpoints cannot satisfy directly. Such a chain passes
   through at least one availability operation and at least one visibility
   operation with inclusive scopes, such that their common scope includes both
   `W` and `R`.

(amdgpu-ordering-comparison)=

## Comparison of Ordering Relations

[This section is informational.]

```{list-table}
:header-rows: 1
:widths: 30 20 25 25

   * - Purpose
     - C++
     - Vulkan
     - AMDGPU
   * - Intra-thread ordering
     - | sequenced-before
       | (transitive)
     - | program-order
       | (transitive)
     - | program-order,
       | dma-program-order
       | (transitive)
   * - Inter-thread synchronization
     - synchronizes-with
     - synchronizes-with
     - synchronizes-with
   * - Transitive inter-thread ordering
     - happens-before
     - inter-thread-happens-before
     - happens-before
   * - Basis for visibility
     - | happens-before
       | (transitive)
     - | happens-before
       | (**not** transitive)
     - | amdgpu-happens-before
       | (**not** transitive)
```

The above table lines up roughly equivalent ordering relations across the
C++, Vulkan, and AMDGPU memory models.

- In C++, *happens-before* is transitive and serves directly as the basis of
  *visible side effects*.
- In Vulkan, the non-transitive *happens-before* serves as the basis of
  *location-order*.
- In AMDGPU, the non-transitive *amdgpu-happens-before* serves the same role.

The Vulkan and AMDGPU models achieve non-transitivity differently:

- Vulkan defines *happens-before* as the union of *program-order* and
  *inter-thread-happens-before*, which are each individually transitive but whose
  union is not.
- AMDGPU defines *amdgpu-happens-before* as the union of the transitive
  *happens-before* and *initiate DMA* edges. *happens-before* additionally
  contains *dma-program-order* and *synchronizes-with* edges from DMA operations.

(amdgcn-av-vulkan)=

## The Vulkan Memory Model

[This section is informational.]

The AMDGPU memory model draws heavily on the Vulkan memory model. In
particular, the following instructions are equivalent.

```{list-table}
:header-rows: 1
:widths: 20 20 60

   * - LLVM
     - SPIRV
     - Available/Visible Semantics
   * - `load`
     - `OpLoad NonPrivatePointer`
     - \-
   * - `load-visible`
     - `OpLoad NonPrivatePointer`
     - `MakePointerVisible`
   * - `store`
     - `OpStore NonPrivatePointer`
     - \-
   * - `store-available`
     - `OpStore NonPrivatePointer`
     - `MakePointerAvailable`
   * - `load atomic`
     - `OpAtomicLoad`
     - `MakePointerVisible`. Also `MakeVisible` when order is at least `acquire`.
   * - `load atomic !{!"amdgcn-av", !"none"}`
     - `OpAtomicLoad`
     - `MakePointerVisible`
   * - `store atomic`
     - `OpAtomicStore`
     - `MakePointerAvailable`. Also `MakeAvailable` when order is at least `release`.
   * - `store atomic !{!"amdgcn-av", !"none"}`
     - `OpAtomicStore`
     - `MakePointerAvailable`
   * - `fence`
     - `OpMemoryBarrier`
     - `MakeAvailable` when order is at least `release`, and `MakeVisible` when order is at least `acquire`.
   * - `fence !{!"amdgcn-av", !"none"}`
     - `OpMemoryBarrier`
     - \-
```

:::{note}
The above table is representative only, and does not aim to be exhaustive. In
particular, it does not list composite atomic operations like `rmw` and
`cmpxchg`. The ordering and semantics of these operations can be determined
by combining suitable rules such as:

- "`MakeAvailable` if the order is at least `release`, and the operation
  results in a store",
- "Only if it is not marked as `!{!"amdgcn-av", !"none"}`", etc.
:::

The AMDGPU memory model is a special case of the Vulkan memory model:

1. LLVM fence/atomic ordering operations have `MakeAvailable` / `MakeVisible`
   semantics by default, thus satisfying the availability and visibility chains
   required in Vulkan. Hence the LLVM memory model is a "strong" subset of the
   Vulkan memory model.
2. The AMDGPU memory model described here makes it possible to opt-out of the
   default `MakeAvailable` and `MakeVisible` semantics, and instead specify it
   on select places including the new *load-visible* and *store-available*
   operations. This expands the subset of the Vulkan memory model that can now
   be expressed in LLVM IR.
