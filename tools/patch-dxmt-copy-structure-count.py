#!/usr/bin/env python3
"""CopyStructureCount with no Metal buffer behind the destination or the counter: skip it instead of crashing.

F1 2020 (F1_2020_dx12.exe, round 620; Send Logs 4W6WMV and G1WB9T, build 614, iPad17,4) died about 20 s in on DXMT's
encode thread: "AV READ of 8" at d3d11.dll+0x8AF18, inside the CopyStructureCount encoder lambda (`ldr x20,[x8,#8]`
with x8 = 0), so one of the two captured buffers was empty: dst_bind->buffer() is an empty Rc for a resource that is not
a plain Metal buffer, and an unordered access view can have no counter. The exception on that native ARM64EC worker
then re-faulted at RIP 0 (2,001 "AV EXEC of 0") until the redelivery guard ended the process.

This patch takes the two buffers before the blit encoder is switched on and returns when either is empty, with one
log line per call site kind ([copy-structure-count] in the log). Only a call that crashed the process changes: with
both buffers present the encoded command is the same as before. Idempotent; fails by name if the anchor moved. Run
from the repository root.
"""
import pathlib
import sys

ROOT = pathlib.Path("dxmt/src")
MARKER = "madeira-bcd: CopyStructureCount without a buffer"
REL = "d3d11/d3d11_context_impl.cpp"

OLD = """    if (auto dst_bind = reinterpret_cast<D3D11ResourceCommon *>(pDstBuffer)) {
      if (auto uav = static_cast<D3D11UnorderedAccessView *>(pSrcView)) {
        SwitchToBlitEncoder(CommandBufferState::BlitEncoderActive);
        EmitOP([=, dst = dst_bind->buffer(), counter = uav->counter()](ArgumentEncodingContext &enc) {
"""
NEW = """    if (auto dst_bind = reinterpret_cast<D3D11ResourceCommon *>(pDstBuffer)) {
      if (auto uav = static_cast<D3D11UnorderedAccessView *>(pSrcView)) {
        /* madeira-bcd: CopyStructureCount without a buffer (round 620, F1 2020: 4W6WMV, G1WB9T). The encoder lambda
         * dereferenced an empty destination or counter on the encode thread and the process died; skip such a call. */
        auto dst_rc = dst_bind->buffer();
        auto counter_rc = uav->counter();
        if (!dst_rc || !counter_rc) {
          static std::atomic<unsigned> skipped{0};
          unsigned n = ++skipped;
          if (n <= 8 || !(n & (n - 1)))
            ERR("[copy-structure-count] skipped #", n, ": ", !dst_rc ? "the destination has no Metal buffer" : "the view has no counter");
          return;
        }
        SwitchToBlitEncoder(CommandBufferState::BlitEncoderActive);
        EmitOP([=, dst = std::move(dst_rc), counter = std::move(counter_rc)](ArgumentEncodingContext &enc) {
"""


def main():
    path = ROOT / REL
    s = path.read_text()
    if MARKER in s:
        print(f"{REL}: already patched")
        return
    if s.count(OLD) != 1:
        sys.exit(f"patch-dxmt-copy-structure-count: anchor not found once in {REL}")
    s = s.replace(OLD, NEW, 1)
    if "#include <atomic>" not in s:
        first = s.index("#include")
        s = s[:first] + "#include <atomic>\n" + s[first:]
    path.write_text(s)
    print(f"{REL}: patched")


main()
