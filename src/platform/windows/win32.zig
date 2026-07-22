// SPDX-License-Identifier: MPL-2.0

pub const api = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("WINVER", "0x0A00");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cInclude("windows.h");
});
