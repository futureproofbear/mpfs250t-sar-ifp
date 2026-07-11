/*******************************************************************************
 * ddr_packet_test.h
 *
 * Self-contained "send a test data packet to DDR and verify it" routine for the
 * PolarFire SoC Icicle Kit (MPFS250T-FCVG484EES).
 *
 * The PolarFire SoC MSS exposes DDR through several address windows. We use the
 * cached, 32-bit window by default; alternatives are listed below so you can
 * exercise the non-cached path (useful to prove the write actually reached DRAM
 * and was not just serviced from the L2 cache).
 *
 *   Cached  (L2)          0x8000_0000  ... and 64-bit at 0x10_0000_0000
 *   Non-cached            0xC000_0000  ... and 64-bit at 0x14_0000_0000
 *   Non-cached Write-Comb 0xD000_0000  ... and 64-bit at 0x18_0000_0000
 ******************************************************************************/
#ifndef DDR_PACKET_TEST_H_
#define DDR_PACKET_TEST_H_

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* DDR windows on the PolarFire SoC MSS. Pick one as the test target. */
#define DDR_CACHED_BASE_32      (0x80000000ULL)
#define DDR_NONCACHED_BASE_32   (0xC0000000ULL)
#define DDR_NONCACHED_WCB_32    (0xD0000000ULL)
#define DDR_CACHED_BASE_64      (0x1000000000ULL)
#define DDR_NONCACHED_BASE_64   (0x1400000000ULL)

/* Magic word used as the packet header signature. */
#define DDR_PKT_MAGIC           (0xDEADBEEFUL)

/* Payload size, in bytes, of one test packet. */
#define DDR_PKT_PAYLOAD_BYTES   (256u)

/*
 * Test "data packet". This is laid out as it will physically sit in DDR:
 * a small header, a payload, then a trailing CRC32 computed over magic .. payload.
 * __attribute__((packed)) keeps the on-DRAM layout deterministic.
 */
typedef struct __attribute__((packed)) {
    uint32_t magic;                          /* DDR_PKT_MAGIC */
    uint32_t length;                         /* payload length in bytes */
    uint32_t sequence;                       /* packet sequence number */
    uint8_t  payload[DDR_PKT_PAYLOAD_BYTES]; /* test data */
    uint32_t crc32;                          /* CRC over magic..payload */
} ddr_test_packet_t;

/* Result codes returned by the verify step. */
typedef enum {
    DDR_PKT_OK            = 0,  /* read-back matched, CRC valid */
    DDR_PKT_HEADER_FAIL  = 1,  /* magic/length/sequence mismatch */
    DDR_PKT_PAYLOAD_FAIL = 2,  /* a payload byte differed */
    DDR_PKT_CRC_FAIL     = 3   /* CRC over read-back data did not match */
} ddr_pkt_result_t;

/*
 * Build a test packet in 'pkt' for the given sequence number, filling the
 * payload with a deterministic, position-dependent pattern and a valid CRC.
 */
void ddr_pkt_build(ddr_test_packet_t *pkt, uint32_t sequence);

/*
 * Write 'pkt' to the DDR address 'ddr_addr', read it back into a separate
 * buffer, and verify header + every payload byte + CRC.
 *
 *   ddr_addr  : DDR window address to use (e.g. DDR_CACHED_BASE_32 + offset)
 *   pkt       : the packet to send (built by ddr_pkt_build)
 *   first_bad : if non-NULL, receives the byte offset of the first mismatch
 *
 * Returns DDR_PKT_OK on success, or a failure code.
 */
ddr_pkt_result_t ddr_pkt_send_and_verify(uint64_t ddr_addr,
                                         const ddr_test_packet_t *pkt,
                                         uint32_t *first_bad);

/* Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320). */
uint32_t ddr_pkt_crc32(const void *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* DDR_PACKET_TEST_H_ */
