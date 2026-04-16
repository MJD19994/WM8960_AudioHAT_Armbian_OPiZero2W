// from http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
unsigned power2(unsigned v)
{
    if (v == 0)
        return 1;
    // Clamp to max power of 2 representable in 32 bits; 2^32 would overflow
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
