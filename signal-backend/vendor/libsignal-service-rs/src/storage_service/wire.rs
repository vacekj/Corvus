//! Minimal protobuf wire-format walking, used to carry fields this crate's
//! protobuf definitions don't know about through a read-modify-write of a
//! storage record (other clients may be newer than us).

use super::StorageServiceError;

/// Field numbers of `ContactRecord` known to `protobuf/StorageService.proto`.
pub(crate) const CONTACT_RECORD_FIELDS: &[u32] = &[
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26,
];

/// Field numbers of `GroupV2Record` known to `protobuf/StorageService.proto`.
pub(crate) const GROUP_V2_RECORD_FIELDS: &[u32] =
    &[1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12];

/// Field numbers of `AccountRecord` known to `protobuf/StorageService.proto`.
pub(crate) const ACCOUNT_RECORD_FIELDS: &[u32] = &[
    1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 21, 22, 23,
    24, 25, 26, 27, 29, 30, 32, 33, 34, 35, 40, 41, 42, 43, 44, 45, 46, 47, 48,
    49, 50, 51,
];

const WIRE_VARINT: u64 = 0;
const WIRE_FIXED64: u64 = 1;
const WIRE_LEN: u64 = 2;
const WIRE_FIXED32: u64 = 5;

fn read_varint(buf: &[u8], pos: &mut usize) -> Result<u64, StorageServiceError> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *buf.get(*pos).ok_or(StorageServiceError::Invalid)?;
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(StorageServiceError::Invalid)
}

pub(crate) fn write_varint(mut value: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

/// One top-level field of an encoded message: its number, and the complete
/// encoded bytes (key included) so it can be copied verbatim.
pub(crate) struct RawField<'a> {
    pub number: u32,
    pub wire_type: u64,
    pub encoded: &'a [u8],
    /// Payload of a length-delimited field (empty for other wire types).
    pub payload: &'a [u8],
}

/// Splits an encoded message into its top-level fields, in order.
pub(crate) fn fields(buf: &[u8]) -> Result<Vec<RawField<'_>>, StorageServiceError> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let start = pos;
        let key = read_varint(buf, &mut pos)?;
        let number = u32::try_from(key >> 3)
            .ok()
            .filter(|n| *n != 0)
            .ok_or(StorageServiceError::Invalid)?;
        let wire_type = key & 7;
        let mut payload: &[u8] = &[];
        match wire_type {
            WIRE_VARINT => {
                read_varint(buf, &mut pos)?;
            },
            WIRE_FIXED64 => pos += 8,
            WIRE_LEN => {
                let len = usize::try_from(read_varint(buf, &mut pos)?)
                    .map_err(|_| StorageServiceError::Invalid)?;
                let end =
                    pos.checked_add(len).ok_or(StorageServiceError::Invalid)?;
                payload = buf.get(pos..end).ok_or(StorageServiceError::Invalid)?;
                pos = end;
            },
            WIRE_FIXED32 => pos += 4,
            // Groups (3, 4) are proto2-only and unused by Signal.
            _ => return Err(StorageServiceError::Invalid),
        }
        if pos > buf.len() {
            return Err(StorageServiceError::Invalid);
        }
        out.push(RawField {
            number,
            wire_type,
            encoded: &buf[start..pos],
            payload,
        });
    }
    Ok(out)
}

/// Encoded bytes of every top-level field whose number is not in `known`.
pub(crate) fn unknown_fields(
    buf: &[u8],
    known: &[u32],
) -> Result<Vec<u8>, StorageServiceError> {
    let mut out = Vec::new();
    for field in fields(buf)? {
        if !known.contains(&field.number) {
            out.extend_from_slice(field.encoded);
        }
    }
    Ok(out)
}

/// Payload of the first length-delimited field `number`, if present.
pub(crate) fn length_delimited(
    buf: &[u8],
    number: u32,
) -> Result<Option<&[u8]>, StorageServiceError> {
    Ok(fields(buf)?
        .into_iter()
        .find(|f| f.number == number && f.wire_type == WIRE_LEN)
        .map(|f| f.payload))
}

/// Encodes `payload` as length-delimited field `number`.
pub(crate) fn encode_length_delimited(number: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 6);
    write_varint((u64::from(number) << 3) | WIRE_LEN, &mut out);
    write_varint(payload.len() as u64, &mut out);
    out.extend_from_slice(payload);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Field numbers declared directly in `message <name>` (nested messages,
    /// enums and `reserved` lines excluded).
    fn proto_field_numbers(name: &str) -> Vec<u32> {
        let proto = include_str!("../../protobuf/StorageService.proto");
        let start = proto
            .find(&format!("message {name} {{"))
            .expect("message present");
        let mut depth = 0i32;
        let mut numbers = Vec::new();
        for (i, line) in proto[start..].lines().enumerate() {
            let line = line.split("//").next().unwrap().trim();
            let opens = line.matches('{').count() as i32;
            let closes = line.matches('}').count() as i32;
            if i == 0 {
                depth = opens - closes;
                continue;
            }
            let at_top = depth == 1;
            depth += opens - closes;
            if depth <= 0 {
                break;
            }
            if !at_top
                || opens > 0
                || line.starts_with("reserved")
                || !line.ends_with(';')
            {
                continue;
            }
            if let Some((_, rhs)) = line.rsplit_once('=') {
                if let Ok(n) = rhs.trim_end_matches(';').trim().parse() {
                    numbers.push(n);
                }
            }
        }
        numbers.sort();
        numbers
    }

    #[test]
    fn known_field_lists_match_proto() {
        assert_eq!(proto_field_numbers("ContactRecord"), CONTACT_RECORD_FIELDS);
        assert_eq!(
            proto_field_numbers("GroupV2Record"),
            GROUP_V2_RECORD_FIELDS
        );
        assert_eq!(proto_field_numbers("AccountRecord"), ACCOUNT_RECORD_FIELDS);
    }

    #[test]
    fn splits_all_wire_types() {
        let mut buf = Vec::new();
        write_varint(1 << 3, &mut buf); // field 1 varint
        write_varint(300, &mut buf);
        write_varint((2 << 3) | 1, &mut buf); // field 2 fixed64
        buf.extend_from_slice(&[1; 8]);
        buf.extend(encode_length_delimited(3, b"abc"));
        write_varint((4 << 3) | 5, &mut buf); // field 4 fixed32
        buf.extend_from_slice(&[2; 4]);
        write_varint(1000 << 3, &mut buf); // field 1000 varint
        write_varint(1, &mut buf);

        let parsed = fields(&buf).unwrap();
        assert_eq!(
            parsed.iter().map(|f| f.number).collect::<Vec<_>>(),
            [1, 2, 3, 4, 1000]
        );
        assert_eq!(parsed[2].payload, b"abc");
        let unknown = unknown_fields(&buf, &[1, 2, 3, 4]).unwrap();
        assert_eq!(unknown, [0xc0, 0x3e, 0x01]);
        assert_eq!(length_delimited(&buf, 3).unwrap(), Some(&b"abc"[..]));
        assert_eq!(length_delimited(&buf, 1).unwrap(), None);
    }

    #[test]
    fn rejects_truncated_input() {
        let buf = encode_length_delimited(3, b"abcdef");
        assert!(fields(&buf[..buf.len() - 1]).is_err());
        assert!(fields(&[0x08]).is_err());
    }
}
