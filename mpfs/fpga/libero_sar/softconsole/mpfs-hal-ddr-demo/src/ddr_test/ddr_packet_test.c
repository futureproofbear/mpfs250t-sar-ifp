/*******************************************************************************
 * ddr_packet_test.c
 *
 * Implementation of the DDR test-packet send/verify routine. No HAL dependency
 * here on purpose -- this is plain C against memory pointers so it is easy to
 * unit-test on a host and reuse from any hart. The MSS HAL is only needed for
 * console output (done in e51.c).
 ******************************************************************************/
#include "ddr_packet_test.h"
#include <string.h>

/*
 * volatile-pointer accessors. 'volatile' matters: it stops the compiler from
 * optimising the write away or fusing the write and the read-back, which would
 * make the test prove nothing.
 */
static inline void w8(uint64_t addr, uint8_t v)
{
    *(volatile uint8_t *)(uintptr_t)addr = v;
}

static inline uint8_t r8(uint64_t addr)
{
    return *(volatile uint8_t *)(uintptr_t)addr;
}

uint32_t ddr_pkt_crc32(const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t crc = 0xFFFFFFFFUL;

    for (size_t i = 0u; i < len; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++) {
            uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320UL & mask);
        }
    }
    return ~crc;
}

void ddr_pkt_build(ddr_test_packet_t *pkt, uint32_t sequence)
{
    pkt->magic    = DDR_PKT_MAGIC;
    pkt->length   = DDR_PKT_PAYLOAD_BYTES;
    pkt->sequence = sequence;

    /*
     * Position-dependent pattern mixed with the sequence number. Using both the
     * index and the sequence means a stuck address line, a stuck data bit, or a
     * stale packet from a previous iteration all produce a visible mismatch.
     */
    for (uint32_t i = 0u; i < DDR_PKT_PAYLOAD_BYTES; i++) {
        pkt->payload[i] = (uint8_t)((i * 7u) ^ (sequence + 0xA5u) ^ (i >> 3));
    }

    /* CRC covers magic..payload (everything up to, but not including, crc32). */
    size_t crc_len = offsetof(ddr_test_packet_t, crc32);
    pkt->crc32 = ddr_pkt_crc32(pkt, crc_len);
}

ddr_pkt_result_t ddr_pkt_send_and_verify(uint64_t ddr_addr,
                                         const ddr_test_packet_t *pkt,
                                         uint32_t *first_bad)
{
    const uint8_t *src = (const uint8_t *)pkt;
    const size_t   n   = sizeof(ddr_test_packet_t);

    /* ---- SEND: copy the packet, byte by byte, into the DDR window. ---- */
    for (size_t i = 0u; i < n; i++) {
        w8(ddr_addr + i, src[i]);
    }

    /* ---- RECEIVE: read the packet back out of DDR into a local buffer. ---- */
    ddr_test_packet_t rb;
    uint8_t *dst = (uint8_t *)&rb;
    for (size_t i = 0u; i < n; i++) {
        dst[i] = r8(ddr_addr + i);
    }

    /* ---- VERIFY header ---- */
    if (rb.magic != DDR_PKT_MAGIC ||
        rb.length != pkt->length  ||
        rb.sequence != pkt->sequence) {
        if (first_bad) *first_bad = 0u;
        return DDR_PKT_HEADER_FAIL;
    }

    /* ---- VERIFY every payload byte against what we sent ---- */
    for (uint32_t i = 0u; i < DDR_PKT_PAYLOAD_BYTES; i++) {
        if (rb.payload[i] != pkt->payload[i]) {
            if (first_bad) {
                *first_bad = (uint32_t)offsetof(ddr_test_packet_t, payload) + i;
            }
            return DDR_PKT_PAYLOAD_FAIL;
        }
    }

    /* ---- VERIFY CRC recomputed over the read-back bytes ---- */
    uint32_t crc = ddr_pkt_crc32(&rb, offsetof(ddr_test_packet_t, crc32));
    if (crc != rb.crc32) {
        if (first_bad) *first_bad = (uint32_t)offsetof(ddr_test_packet_t, crc32);
        return DDR_PKT_CRC_FAIL;
    }

    return DDR_PKT_OK;
}
