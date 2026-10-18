| Variant | Credential | Request bytes | Response bytes | Request body | Credential bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| `json` | `Authorization` header | 1538 | 827 | 241 | 696 |
| `cbor` | `Authorization` header | 1505 | 757 | 208 | 696 |
| `cose` | signature in the body | 1606 | 1302 | 765 | 557 |


| Op | Payload | External AAD | Body | Added | Added % |
| --- | ---: | ---: | ---: | ---: | ---: |
| `procedure.addNote` | 43 | 102 | 155 | 112 | 260.5% |
| `procedure.addNote` | 43 | 102 | 155 | 112 | 260.5% |
| `procedure.listNotes` | 7 | 104 | 118 | 111 | 1585.7% |
| `procedure.listNotes` | 7 | 104 | 118 | 111 | 1585.7% |
| `procedure.listNotes` | 7 | 104 | 118 | 111 | 1585.7% |
| **Total** | **107** | | | **557** | |


| Op | Call | JSON | CBOR | COSE |
| --- | ---: | ---: | ---: | ---: |
| `procedure.registerDevice` | 1 | 1 × 331 = 331 | 1 × 322 = 322 | 1 × 206 = 206 |
| `procedure.addNote` | 2 | 2 × 263 = 526 | 2 × 257 = 514 | 2 × 301 = 602 |
| `procedure.listNotes` | 3 | 3 × 227 = 681 | 3 × 223 = 669 | 3 × 266 = 798 |


| Op | Variant | Head/call | Body/call | Total/call | Credential |
| --- | --- | ---: | ---: | ---: | --- |
| `procedure.registerDevice` | `json` | 221 | 110 | 331 | 116 B header |
| `procedure.registerDevice` | `cbor` | 221 | 101 | 322 | 116 B header |
| `procedure.registerDevice` | `cose` | 105 | 101 | 206 | in the body |
| `procedure.addNote` | `json` | 214 | 49 | 263 | 116 B header |
| `procedure.addNote` | `cbor` | 214 | 43 | 257 | 116 B header |
| `procedure.addNote` | `cose` | 146 | 155 | 301 | in the body |
| `procedure.listNotes` | `json` | 216 | 11 | 227 | 116 B header |
| `procedure.listNotes` | `cbor` | 216 | 7 | 223 | 116 B header |
| `procedure.listNotes` | `cose` | 148 | 118 | 266 | in the body |


**The credential, compared directly.**

| Credential | Bytes | Where |
| --- | ---: | --- |
| `json` `Bearer` header | 116 | in the head (696 over 6 calls) |
| `cbor` `Bearer` header | 116 | in the head (696 over 6 calls) |
| `cose` signature | 111 | in the body (557 over 5 sealed calls) |

