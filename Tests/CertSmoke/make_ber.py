"""Reescreve um .p12 DER no formato BER (comprimentos indefinidos e o
OCTET STRING do conteúdo em pedaços), como fazem o Windows e o Java.
O MAC continua valendo, porque ele é calculado sobre o conteúdo."""
import sys


def read(b, i):
    tag = b[i]
    i += 1
    length = b[i]
    i += 1
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(b[i:i + n], "big")
        i += n
    return tag, b[i:i + length], i + length


def enc(tag, content):
    n = len(content)
    if n < 0x80:
        head = bytes([n])
    else:
        raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
        head = bytes([0x80 | len(raw)]) + raw
    return bytes([tag]) + head + content


def indefinite(tag, parts):
    return bytes([tag, 0x80]) + b"".join(parts) + b"\x00\x00"


data = open(sys.argv[1], "rb").read()
_, pfx, _ = read(data, 0)
_, version, i = read(pfx, 0)
version = enc(0x02, version)
_, content_info, j = read(pfx, i)
mac = pfx[j:]
_, oid, k = read(content_info, 0)
_, wrapper, _ = read(content_info, k)
_, auth, _ = read(wrapper, 0)
chunks = [enc(0x04, auth[x:x + 1000]) for x in range(0, len(auth), 1000)]
octets = indefinite(0x24, chunks)
new_ci = indefinite(0x30, [enc(0x06, oid), indefinite(0xA0, [octets])])
open(sys.argv[2], "wb").write(indefinite(0x30, [version, new_ci, mac]))
