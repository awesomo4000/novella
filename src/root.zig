// SPDX-License-Identifier: MPL-2.0

//! Publication-quality paragraph justification for custom Zig renderers.
//!
//! `novella` deliberately does not own a font stack. A renderer supplies one
//! measurement callback, then receives word ranges and exact inter-word
//! spacing for each chosen line. That keeps the Knuth-Plass core useful with
//! CoreText, FreeType, browser canvases, terminal cells, or test metrics.

const justify = @import("justify.zig");

pub const inf_bad = justify.inf_bad;
pub const Fitness = justify.Fitness;
pub const badness = justify.badness;
pub const fitness = justify.fitness;
pub const lineDemerits = justify.lineDemerits;
pub const Measurer = justify.Measurer;
pub const Options = justify.Options;
pub const Word = justify.Word;
pub const Line = justify.Line;
pub const Layout = justify.Layout;

test {
    _ = justify;
}
