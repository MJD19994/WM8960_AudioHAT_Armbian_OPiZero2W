// from http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
unsigned power2(unsigned v)
{
    if (v == 0)
        return 1;
    // 2^32 is not representable in 32-bit unsigned. For v > 0x80000000 the
    // next power of two doesn't fit, so we clamp to 0x80000000 — callers
    // requesting a larger size get a smaller buffer silently. Callers must
    // bound input upstream (CLI validation handles this; realistic ring
    // buffer sizes are <1 MiB).
    if (v > 0x80000000u)
        return 0x80000000u;
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;

    return v;
}
