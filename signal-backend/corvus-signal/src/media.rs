//! Outgoing files: content type and image dimensions for attachment uploads.

use std::path::Path;

use presage::libsignal_service::sender::AttachmentSpec;

/// The content type of a file: sniffed from its first bytes, else from its extension.
pub fn content_type(path: &Path, bytes: &[u8]) -> String {
    if let Some(ct) = sniff(bytes) {
        return ct.to_owned();
    }
    mime_guess::from_path(path)
        .first_raw()
        .unwrap_or("application/octet-stream")
        .to_owned()
}

fn sniff(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        Some("image/webp")
    } else if b.len() >= 12 && &b[4..8] == b"ftyp" {
        match &b[8..12] {
            b"qt  " => Some("video/quicktime"),
            b"M4A " | b"M4B " => Some("audio/mp4"),
            b"heic" | b"heix" | b"mif1" => Some("image/heic"),
            _ => Some("video/mp4"),
        }
    } else if b.starts_with(b"%PDF-") {
        Some("application/pdf")
    } else {
        None
    }
}

/// Width and height of a PNG, GIF, JPEG or WebP image.
pub fn image_size(b: &[u8]) -> Option<(u32, u32)> {
    let be16 = |i: usize| Some(u16::from_be_bytes([*b.get(i)?, *b.get(i + 1)?]) as u32);
    let le16 = |i: usize| Some(u16::from_le_bytes([*b.get(i)?, *b.get(i + 1)?]) as u32);
    let be32 = |i: usize| Some(u32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?));
    let le24 = |i: usize| Some(u32::from_le_bytes([*b.get(i)?, *b.get(i + 1)?, *b.get(i + 2)?, 0]));
    match sniff(b)? {
        "image/png" => Some((be32(16)?, be32(20)?)),
        "image/gif" => Some((le16(6)?, le16(8)?)),
        "image/webp" => match b.get(12..16)? {
            b"VP8 " => Some((le16(26)? & 0x3FFF, le16(28)? & 0x3FFF)),
            b"VP8L" => {
                let bits = u32::from_le_bytes(b.get(21..25)?.try_into().ok()?);
                Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1))
            }
            b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
            _ => None,
        },
        "image/jpeg" => {
            let mut i = 2;
            while i + 9 < b.len() {
                if b[i] != 0xFF {
                    i += 1;
                    continue;
                }
                let marker = b[i + 1];
                if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
                    return Some((be16(i + 7)?, be16(i + 5)?));
                }
                if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) || marker == 0xFF {
                    i += if marker == 0xFF { 1 } else { 2 };
                    continue;
                }
                i += 2 + be16(i + 2)? as usize;
            }
            None
        }
        _ => None,
    }
}

/// Reads a file for upload. Returns the spec and the bytes.
pub fn attachment_from_file(
    path: &Path,
    voice_note: bool,
) -> std::io::Result<(AttachmentSpec, Vec<u8>)> {
    let bytes = std::fs::read(path)?;
    let content_type = content_type(path, &bytes);
    let (width, height) = match image_size(&bytes) {
        Some((w, h)) => (Some(w), Some(h)),
        None => (None, None),
    };
    let spec = AttachmentSpec {
        content_type,
        length: bytes.len(),
        file_name: path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|_| !voice_note),
        preview: None,
        voice_note: voice_note.then_some(true),
        borderless: None,
        width,
        height,
        caption: None,
        blur_hash: None,
    };
    Ok((spec, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_and_gif_sizes() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&640u32.to_be_bytes());
        png.extend_from_slice(&480u32.to_be_bytes());
        assert_eq!(image_size(&png), Some((640, 480)));
        assert_eq!(content_type(Path::new("x.bin"), &png), "image/png");

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&[0x20, 0x01, 0x10, 0x00]);
        assert_eq!(image_size(&gif), Some((288, 16)));
    }

    #[test]
    fn jpeg_size() {
        // SOI, APP0 (len 4), SOF0 with height 300, width 400
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C,
            0x01, 0x90, 0x03, 0x00, 0x00, 0x00,
        ];
        assert_eq!(image_size(&jpeg), Some((400, 300)));
    }

    #[test]
    fn extension_fallback() {
        assert_eq!(content_type(Path::new("a.txt"), b"hello"), "text/plain");
        assert_eq!(content_type(Path::new("noext"), b"hello"), "application/octet-stream");
        assert_eq!(content_type(Path::new("v.m4a"), b"\0\0\0\x20ftypM4A \0\0"), "audio/mp4");
    }
}
