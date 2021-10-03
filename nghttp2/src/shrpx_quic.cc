/*
 * nghttp2 - HTTP/2 C Library
 *
 * Copyright (c) 2021 Tatsuhiro Tsujikawa
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
#include "shrpx_quic.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/udp.h>

#include <array>
#include <chrono>

#include <ngtcp2/ngtcp2_crypto.h>

#include <nghttp3/nghttp3.h>

#include <openssl/rand.h>

#include "shrpx_config.h"
#include "shrpx_log.h"
#include "util.h"
#include "xsi_strerror.h"

bool operator==(const ngtcp2_cid &lhs, const ngtcp2_cid &rhs) {
  return ngtcp2_cid_eq(&lhs, &rhs);
}

namespace shrpx {

ngtcp2_tstamp quic_timestamp() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

int quic_send_packet(const UpstreamAddr *faddr, const sockaddr *remote_sa,
                     size_t remote_salen, const sockaddr *local_sa,
                     size_t local_salen, const uint8_t *data, size_t datalen,
                     size_t gso_size) {
  iovec msg_iov = {const_cast<uint8_t *>(data), datalen};
  msghdr msg{};
  msg.msg_name = const_cast<sockaddr *>(remote_sa);
  msg.msg_namelen = remote_salen;
  msg.msg_iov = &msg_iov;
  msg.msg_iovlen = 1;

  uint8_t msg_ctrl[
#ifdef UDP_SEGMENT
      CMSG_SPACE(sizeof(uint16_t)) +
#endif // UDP_SEGMENT
      CMSG_SPACE(sizeof(in6_pktinfo))];

  memset(msg_ctrl, 0, sizeof(msg_ctrl));

  msg.msg_control = msg_ctrl;
  msg.msg_controllen = sizeof(msg_ctrl);

  size_t controllen = 0;

  auto cm = CMSG_FIRSTHDR(&msg);

  switch (local_sa->sa_family) {
  case AF_INET: {
    controllen += CMSG_SPACE(sizeof(in_pktinfo));
    cm->cmsg_level = IPPROTO_IP;
    cm->cmsg_type = IP_PKTINFO;
    cm->cmsg_len = CMSG_LEN(sizeof(in_pktinfo));
    auto pktinfo = reinterpret_cast<in_pktinfo *>(CMSG_DATA(cm));
    memset(pktinfo, 0, sizeof(in_pktinfo));
    auto addrin =
        reinterpret_cast<sockaddr_in *>(const_cast<sockaddr *>(local_sa));
    pktinfo->ipi_spec_dst = addrin->sin_addr;
    break;
  }
  case AF_INET6: {
    controllen += CMSG_SPACE(sizeof(in6_pktinfo));
    cm->cmsg_level = IPPROTO_IPV6;
    cm->cmsg_type = IPV6_PKTINFO;
    cm->cmsg_len = CMSG_LEN(sizeof(in6_pktinfo));
    auto pktinfo = reinterpret_cast<in6_pktinfo *>(CMSG_DATA(cm));
    memset(pktinfo, 0, sizeof(in6_pktinfo));
    auto addrin =
        reinterpret_cast<sockaddr_in6 *>(const_cast<sockaddr *>(local_sa));
    pktinfo->ipi6_addr = addrin->sin6_addr;
    break;
  }
  default:
    assert(0);
  }

#ifdef UDP_SEGMENT
  if (gso_size && datalen > gso_size) {
    controllen += CMSG_SPACE(sizeof(uint16_t));
    cm = CMSG_NXTHDR(&msg, cm);
    cm->cmsg_level = SOL_UDP;
    cm->cmsg_type = UDP_SEGMENT;
    cm->cmsg_len = CMSG_LEN(sizeof(uint16_t));
    *(reinterpret_cast<uint16_t *>(CMSG_DATA(cm))) = gso_size;
  }
#endif // UDP_SEGMENT

  msg.msg_controllen = controllen;

  ssize_t nwrite;

  do {
    nwrite = sendmsg(faddr->fd, &msg, 0);
  } while (nwrite == -1 && errno == EINTR);

  if (nwrite == -1) {
    return -1;
  }

  if (LOG_ENABLED(INFO)) {
    LOG(INFO) << "QUIC sent packet: local="
              << util::to_numeric_addr(local_sa, local_salen)
              << " remote=" << util::to_numeric_addr(remote_sa, remote_salen)
              << " " << nwrite << " bytes";
  }

  return 0;
}

int generate_quic_connection_id(ngtcp2_cid &cid, size_t cidlen) {
  if (RAND_bytes(cid.data, cidlen) != 1) {
    return -1;
  }

  cid.datalen = cidlen;

  return 0;
}

int generate_encrypted_quic_connection_id(ngtcp2_cid &cid, size_t cidlen,
                                          const uint8_t *cid_prefix,
                                          const uint8_t *key) {
  assert(cidlen > SHRPX_QUIC_CID_PREFIXLEN);

  auto p = std::copy_n(cid_prefix, SHRPX_QUIC_CID_PREFIXLEN, cid.data);

  if (RAND_bytes(p, cidlen - SHRPX_QUIC_CID_PREFIXLEN) != 1) {
    return -1;
  }

  cid.datalen = cidlen;

  return encrypt_quic_connection_id(cid.data, cid.data, key);
}

int encrypt_quic_connection_id(uint8_t *dest, const uint8_t *src,
                               const uint8_t *key) {
  auto ctx = EVP_CIPHER_CTX_new();
  auto d = defer(EVP_CIPHER_CTX_free, ctx);

  if (!EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), nullptr, key, nullptr)) {
    return -1;
  }

  EVP_CIPHER_CTX_set_padding(ctx, 0);

  int len;

  if (!EVP_EncryptUpdate(ctx, dest, &len, src, SHRPX_QUIC_DECRYPTED_DCIDLEN) ||
      !EVP_EncryptFinal_ex(ctx, dest + len, &len)) {
    return -1;
  }

  return 0;
}

int decrypt_quic_connection_id(uint8_t *dest, const uint8_t *src,
                               const uint8_t *key) {
  auto ctx = EVP_CIPHER_CTX_new();
  auto d = defer(EVP_CIPHER_CTX_free, ctx);

  if (!EVP_DecryptInit_ex(ctx, EVP_aes_128_ecb(), nullptr, key, nullptr)) {
    return -1;
  }

  EVP_CIPHER_CTX_set_padding(ctx, 0);

  int len;

  if (!EVP_DecryptUpdate(ctx, dest, &len, src, SHRPX_QUIC_DECRYPTED_DCIDLEN) ||
      !EVP_DecryptFinal_ex(ctx, dest + len, &len)) {
    return -1;
  }

  return 0;
}

int generate_quic_hashed_connection_id(ngtcp2_cid &dest,
                                       const Address &remote_addr,
                                       const Address &local_addr,
                                       const ngtcp2_cid &cid) {
  auto ctx = EVP_MD_CTX_new();
  auto d = defer(EVP_MD_CTX_free, ctx);

  std::array<uint8_t, 32> h;
  unsigned int hlen = EVP_MD_size(EVP_sha256());

  if (!EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) ||
      !EVP_DigestUpdate(ctx, &remote_addr.su.sa, remote_addr.len) ||
      !EVP_DigestUpdate(ctx, &local_addr.su.sa, local_addr.len) ||
      !EVP_DigestUpdate(ctx, cid.data, cid.datalen) ||
      !EVP_DigestFinal_ex(ctx, h.data(), &hlen)) {
    return -1;
  }

  assert(hlen == h.size());

  std::copy_n(std::begin(h), sizeof(dest.data), std::begin(dest.data));
  dest.datalen = sizeof(dest.data);

  return 0;
}

int generate_quic_stateless_reset_token(uint8_t *token, const ngtcp2_cid &cid,
                                        const uint8_t *secret,
                                        size_t secretlen) {
  if (ngtcp2_crypto_generate_stateless_reset_token(token, secret, secretlen,
                                                   &cid) != 0) {
    return -1;
  }

  return 0;
}

int generate_quic_stateless_reset_secret(uint8_t *secret) {
  if (RAND_bytes(secret, SHRPX_QUIC_STATELESS_RESET_SECRETLEN) != 1) {
    return -1;
  }

  return 0;
}

int generate_quic_token_secret(uint8_t *secret) {
  if (RAND_bytes(secret, SHRPX_QUIC_TOKEN_SECRETLEN) != 1) {
    return -1;
  }

  return 0;
}

int generate_retry_token(uint8_t *token, size_t &tokenlen, const sockaddr *sa,
                         socklen_t salen, const ngtcp2_cid &retry_scid,
                         const ngtcp2_cid &odcid, const uint8_t *token_secret) {
  auto t = std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::system_clock::now().time_since_epoch())
               .count();

  auto stokenlen = ngtcp2_crypto_generate_retry_token(
      token, token_secret, SHRPX_QUIC_TOKEN_SECRETLEN, sa, salen, &retry_scid,
      &odcid, t);
  if (stokenlen < 0) {
    return -1;
  }

  tokenlen = stokenlen;

  return 0;
}

int verify_retry_token(ngtcp2_cid &odcid, const uint8_t *token, size_t tokenlen,
                       const ngtcp2_cid &dcid, const sockaddr *sa,
                       socklen_t salen, const uint8_t *token_secret) {

  auto t = std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::system_clock::now().time_since_epoch())
               .count();

  if (ngtcp2_crypto_verify_retry_token(&odcid, token, tokenlen, token_secret,
                                       SHRPX_QUIC_TOKEN_SECRETLEN, sa, salen,
                                       &dcid, 10 * NGTCP2_SECONDS, t) != 0) {
    return -1;
  }

  return 0;
}

int generate_token(uint8_t *token, size_t &tokenlen, const sockaddr *sa,
                   size_t salen, const uint8_t *token_secret) {
  auto t = std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::system_clock::now().time_since_epoch())
               .count();

  auto stokenlen = ngtcp2_crypto_generate_regular_token(
      token, token_secret, SHRPX_QUIC_TOKEN_SECRETLEN, sa, salen, t);
  if (stokenlen < 0) {
    return -1;
  }

  tokenlen = stokenlen;

  return 0;
}

int verify_token(const uint8_t *token, size_t tokenlen, const sockaddr *sa,
                 socklen_t salen, const uint8_t *token_secret) {
  auto t = std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::system_clock::now().time_since_epoch())
               .count();

  if (ngtcp2_crypto_verify_regular_token(token, tokenlen, token_secret,
                                         SHRPX_QUIC_TOKEN_SECRETLEN, sa, salen,
                                         3600 * NGTCP2_SECONDS, t) != 0) {
    return -1;
  }

  return 0;
}

} // namespace shrpx
