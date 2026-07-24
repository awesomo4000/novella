// SPDX-License-Identifier: MPL-2.0

const builtin = @import("builtin");

pub const api = @cImport({
    if (builtin.cpu.arch == .x86) @cDefine("_X86_", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("WINVER", "0x0601");
    @cDefine("_WIN32_WINNT", "0x0601");
    @cInclude("windows.h");
});
