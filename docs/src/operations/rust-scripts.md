# Rust CLI scripts: living requirements

Status: requirements capture only. No Rust port is implemented by this page.
Add future requirements here as the owner supplies them; keep the original
prose below and distinguish subsequent decisions from editorial notes.

The concrete starting point is `packs/modrinth.sh`. The intended destination
is a Rust crate under `scripts/` for the useful glue scripts, with clap CLIs
and generally equivalent behavior. This page records design intent, not
current implementation behavior.

## Requirements at a glance

- Separate external APIs from core logic through an Anti-Corruption Layer
  (ACL), using owned response schemas, serde and reqwest. Translate API data,
  errors and behavioral quirks at that boundary into internal types.
- Use explicit error enums with thiserror throughout, including core logic.
  Avoid unwraps; never return bare string errors or silently discard errors.
- Model state with sum types and declarative transitions, rather than
  implicit state machines or boolean switches such as an `on` flag. Use
  builders where appropriate; use Option for simple optional data.
- Keep execution synchronous unless a future need justifies async. Use
  dotenvy for environment configuration and tracing for logging. Capture
  error call stacks in logs or, potentially, CI artifacts; the precise
  diagnostics mechanism remains to be decided.
- Begin the future design with tests and probing questions in the style of
  Matt Pocock's `/grill-me`. Keep tests alongside the toolkit. This is a
  requirement for the future port, not a request to implement it now.
- Put high-level documentation in this mdBook and technical documentation
  beside the code using rustdoc.

## The Modrinth example

Preserve the script's general publishing workflow: build each requested
pack, find or create its project, avoid publishing identical files, derive
release metadata and the changelog, synchronize project metadata, and
handle draft review submission. The original script remains the concrete
reference for details that have not yet been discussed.

A preflight check should deduce whether a file hash already exists using the
versions read from Modrinth. A concurrent upload can still race that check
(TOCTOU), so the ACL must also handle duplicate rejection at upload time.
Represent that condition as an explicit ACL error. CI policy catches that
specific error, logs the fact and treats that scenario as successful.
Other failures must retain explicit handling rather than being silently
converted into success.

Map shell cleanup through `trap` to resource ownership and Drop. Use reqwest
for headers and typed HTTP status handling. Represent short and full Git
identifiers explicitly, including the script's 7–40-character validation.
Use the builder interface of `std::process::Command` for `nix build`.
Keep API request construction, response parsing and API-specific data
transformations in the ACL. Pass internal types into the publishing logic.
Keep changelog data separate from rendering, with an optional comparison
link represented by Option.

## Follow-up: booleans and explicit domain types

The owner supplied a subsequent discussion and made these clarifications:

> booleans should be forbidden when we have options tho
>
> no, verbosity is an enum of levels

Read these alongside the original requirement to represent state explicitly.
For optional data, use Option rather than a boolean tracking whether a
separate value exists. For verbosity, model the levels with an enum rather
than a verbose boolean. These examples supplement the original prose; they
do not replace its preference for explicit state types.

The other chat argued that enums can improve meaning even with two variants,
while distinguishing that readability benefit from preventing invalid states.
It also proposed a boolean dry-run setting as a counterexample. Those are
the other chat's arguments, not additional requirements accepted by the
owner. The supplied exchange does not settle that counterexample or specify
the exact verbosity levels for these CLIs.

## Notes to resolve during future design

These are editorial notes, separate from the owner's original prose.

- The duplicate-hash claims in the supplied screenshot are unverified here,
  including their scope across projects and versions and the exact rejection
  response. Verify against primary Modrinth sources before encoding them.
  The required split between ACL errors and CI policy is already explicit.
- The original prose calls the HTTP match a “reqwest response enum”. The
  intent is typed HTTP status handling; the exact library types belong in
  the future technical design.
- The prose refers to Git tags; the current script obtains commit hashes
  using `git rev-parse`. Clarify terminology and accepted identifier lengths
  during design without silently changing the requested short/full model.
- Drop expresses ownership-based cleanup. How cleanup failures are surfaced
  must be reconciled with the requirement against silent errors.
- The first screenshot describes duplicate-hash rejection. The second shows
  changelog data with a commit and an optional diff link, rendered together.
  Those images are context, not independently verified API documentation.
- Consult the owner's existing local projects when designing:
  `serenity-discord-bot`, `cli-utils`, `mcopts`, `skavex`, and `hu-tao.dev`.
  The owner reports checkouts under `~/Projects` or sources in the Nix store;
  these have not been inspected for this requirements capture.

## Original requirements prose

The following preserves the owner's wording, with line wrapping for Markdown.

I'll write this prose once, I don't want an implementation just make sure you
save the prose and add to it as I write out my requirements with this concrete
example

Going off modrinth.sh

I want to have Rust CLIs with clap for all of these glue scripts because it's
far more maintainable in the long run and these scripts have officially become
useful. I suggest we can have it as a rust crate in scripts/ entirely rather
than scatter around scripts in places like packs/. The scripts will have the
same functionality generally but we'd write our own response schemas and use
serde and reqwests. This is the common pattern of having an internal
abstraction for external APIs such as modrinths and it comes in handy whenever
modrinth makes a change to their API signatures. We can update our
abstraction's internals whilst keeping our core functionality intact as that
abstraction will give us the interfaces for our functionality so our
functionality is separate from their APIs. I looked it up this is Eric Evans'
ACL (Anti-Corruption Layer) in Domain-Driven Design. Additionally when
designing this Rust port I want you to start with tests and ask me questions
(similar to the /grill-me skill from matt pocock). You can work on
documentation regarding the scripts in 2 separate places: the mdbook for high
level overviews and the source code itself for the actual technical
documentation (rustdoc is amazing). Some more invariants I want to mention:
You need to be the type of person that writes idiomatic Rust. Which means to
avoid unwraps and by all means necessary NEVER and I mean NEVER provide bare
string or silent errors. Use thiserror with explicit enum types for all of
them. I also want you to heavily represent state using the type system. Rust
provides you with amazing sum type enums, please utilize them for state
handling I don't want the "on" boolean ever! State transitions should be
declarative. I also like the builder pattern when defining structs.

So how would I see this modrinth.sh script being recreated in high level
prose?

the ACL layer for all the modrinth stuff
With explicit error handling and serde parsing
that way we can pass the types cleanly afterwards for our actual logic
where the actual logic will be documented in the code using rustdoc and we'll
still expect errors there
environment variables will work with dotenvy
we can use reqwest

I also looked up the specific behavior modrinth's api has (feel free to fact
check it, it was with another ai in the screenshot). Behavior like this and
its handling should also be a part of the ACL layer. Fortunately we can do the
hash deduction ahead of time based on our read request of all the versions but
additionally provide it at time because of a possible TOCTOU. Also I believe
this to be an error unlike what brave ai has told me. The difference is how
it's treated and where. In our ACL layer - error. In our CI logic layer - we
take that error and in that scenario we treat the pipeline as successful but
log the fact

for logging we'll use tracing and for errors we'll log the call stack (or save
it as an artifact maybe)

now for the concrete examples porting over from the script but doing them in
prose because I'm too lazy to write code:

trap ...

that's your Drop implementation

the headers are solved from reqwest
the version works as is but obviously we'd want it to be a readable enum for
the git tag with short and long (this applies later on the 7/40 split too)
the nix build command is a perfect thing to use the builder pattern on and
Rust's std Command already gives it to us for free. this is also where I
should mention async is overkill for these scripts. We can keep it in mind but
only if it becomes needed in the future
the switch on cases 200 and so on are perfect contenders for reqwest's
response enum, and the data overrides are the perfect thing to put in the ACL
layer with serde because it relies on transforming the API response or making
requests to the API
the changelog with string and then appending is a bit ugly and in Rust I
wouldn't write it like that. The AI gave that suggestion and honestly Option
is reasonable because the state isn't complex enough to require granular
handling

Basically we'd save ourselves all the jq and curl mess whilst also enforcing
proper error handling, no implicit state machines and have tests alongside the
rust toolkit. I've done similar things in a handful of other projects like
serenity-discord-bot, cli-utils, mcopts and so on. All should be either
available as local checkouts in ~/Projects or in my nix store. I've also
implemented some of these patterns outside of Rust like in my skavex library
or my hu-tao.dev site (both checked out locally)
