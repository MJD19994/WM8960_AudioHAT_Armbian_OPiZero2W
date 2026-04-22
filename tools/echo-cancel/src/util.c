// from http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
unsigned power2(unsigned v)
{
    if (v == 0)
        return 1;
    // 2^32 is not representable in 32-bit unsigned. Signal overflow by
    // returning 0 so callers fail loud (pa_ringbuffer rejects elementCount
    // == 0 and propagates the error) rather than silently allocating a
    // buffer smaller than requested. power2(0) returns 1, so 0 is a safe
    // sentinel that never collides with a valid result.
    if (v > 0x80000000u)
        return 0;
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;

    return v;
}
