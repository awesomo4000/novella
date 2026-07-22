// SPDX-License-Identifier: MPL-2.0

import fs from "node:fs";
import {
  breakParagraph,
  buildItems,
  defaultBreakOptions,
  defaultBuildOptions,
  layoutLines,
  lineText,
} from "justif/core";

const cases = [
  ["balanced", 22, "one two three four five six seven eight nine ten eleven twelve"],
  ["uneven", 27, "a gathering storm moved quietly beyond the western ridge before morning"],
  ["narrow", 16, "paper windows remember every room that silence leaves behind"],
  ["punctuation", 24, "At first, the house waited; then the old stair answered softly."],
  ["short-ending", 30, "The lamp burned late while rain crossed the garden and vanished."],
];

const zigRows = new Map(
  fs.readFileSync(process.argv[2], "utf8")
    .trim()
    .split("\n")
    .map((row) => {
      const [name, demerits, lines, ratios] = row.split("\t");
      return [name, {
        demerits: Number(demerits),
        lines: lines.split("\x1f"),
        ratios: ratios.split(",").map(Number),
      }];
    }),
);

const metrics = {
  fontKey: "oracle-monospace",
  familyKey: "oracle-monospace",
  space: { width: 1, stretch: 0.5, shrink: 1 / 3 },
  hyphenWidth: 1,
  ratioAtMax: 1,
  ratioAtMin: 1,
};
const measure = {
  width: (text) => text.length,
  charAdvance: () => 1,
};
const buildOptions = {
  ...defaultBuildOptions,
  hyphenPenalty: 50,
  exHyphenPenalty: 50,
  protrusion: false,
  expansion: false,
  tracking: false,
  lastLineFit: 0,
  lastLineMinWidth: 0,
  boundaryShrink: 0,
};
const breakOptions = {
  ...defaultBreakOptions,
  pretolerance: 100,
  tolerance: 200,
  linePenalty: 10,
  adjDemerits: 10_000,
  doubleHyphenDemerits: 10_000,
  finalHyphenDemerits: 5_000,
  emergencyStretch: "auto",
  lastLineMinWidth: 0,
};

let failures = 0;
for (const [name, width, text] of cases) {
  const paragraph = buildItems([{ text, run: 0 }], [metrics], buildOptions, measure);
  const breaks = breakParagraph(paragraph, width, breakOptions);
  const lines = layoutLines(paragraph, breaks, width, buildOptions);
  const actual = {
    demerits: breaks.demerits,
    lines: lines.map((line) => lineText(paragraph, line)),
    ratios: lines.map((line) => line.ratio),
  };
  const zig = zigRows.get(name);
  const sameLines = JSON.stringify(zig?.lines) === JSON.stringify(actual.lines);
  const sameDemerits = zig?.demerits === actual.demerits;
  const sameRatios = zig?.ratios.length === actual.ratios.length &&
    zig.ratios.every((ratio, index) =>
      ratio === actual.ratios[index] || Math.abs(ratio - actual.ratios[index]) < 1e-9
    );
  if (!sameLines || !sameDemerits || !sameRatios) {
    failures++;
    console.error(`${name}: mismatch`);
    console.error("  Zig:  ", zig);
    console.error("  justif:", actual);
  } else {
    console.log(`${name}: ${actual.lines.length} lines, exact match`);
  }
}

if (failures > 0) process.exit(1);
console.log(`oracle: ${cases.length}/${cases.length} cases match justif 0.4.2`);
