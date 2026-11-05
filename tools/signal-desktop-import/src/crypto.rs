//! Signal Desktop key and attachment decryption.

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::Sha256;

type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

/// Electron safeStorage on macOS (Chromium os_crypt "v10"): PBKDF2-SHA1(password, "saltysalt",
/// 1003 rounds) -> AES-128-CBC key, IV = 16 spaces. Returns the plaintext (the SQLCipher key, hex).
pub fn safe_storage_decrypt(encrypted_hex: &str, password: &[u8]) -> Result<String, String> {
    let data = hex::decode(encrypted_hex.trim()).map_err(|_| "config.json: encryptedKey is not hex")?;
    let body = data.strip_prefix(b"v10").ok_or("config.json: unsupported encryptedKey version")?;
    let mut key = [0u8; 16];
    pbkdf2::pbkdf2_hmac::<sha1::Sha1>(password, b"saltysalt", 1003, &mut key);
    let iv = [b' '; 16];
    let mut buf = body.to_vec();
    let plain = Aes128CbcDec::new(&key.into(), &iv.into())
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| "the Signal Safe Storage key did not decrypt the database key")?;
    String::from_utf8(plain.to_vec()).map_err(|_| "decrypted database key is not text".into())
}

/// Signal Desktop attachment file (version 2): IV(16) || AES-256-CBC(PKCS7) || HMAC-SHA256(32),
/// localKey = base64(aesKey(32) || macKey(32)). `size` (if > 0) trims padding after the plaintext.
pub fn decrypt_attachment(data: &[u8], local_key_b64: &str, size: i64) -> Result<Vec<u8>, String> {
    let key = base64::engine::general_purpose::STANDARD
        .decode(local_key_b64)
        .map_err(|_| "bad localKey")?;
    if key.len() != 64 {
        return Err("bad localKey length".into());
    }
    if data.len() < 16 + 16 + 32 {
        return Err("attachment file too short".into());
    }
    let (body, mac) = data.split_at(data.len() - 32);
    let mut h = <Hmac<Sha256> as Mac>::new_from_slice(&key[32..]).unwrap();
    h.update(body);
    h.verify_slice(mac).map_err(|_| "attachment MAC mismatch")?;
    let (iv, ct) = body.split_at(16);
    let mut buf = ct.to_vec();
    let iv: [u8; 16] = iv.try_into().unwrap();
    let key32: [u8; 32] = key[..32].try_into().unwrap();
    let plain = Aes256CbcDec::new(&key32.into(), &iv.into())
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| "attachment decryption failed")?;
    let mut out = plain.to_vec();
    if size > 0 && (size as usize) < out.len() {
        out.truncate(size as usize);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockEncryptMut;
    type Aes256CbcEnc = cbc::Encryptor<aes::Aes256>;
    type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

    #[test]
    fn attachment_roundtrip() {
        let key: Vec<u8> = (0u8..64).collect();
        let iv = [7u8; 16];
        let plain = b"hello attachment\0\0\0\0";
        let mut buf = plain.to_vec();
        buf.resize(plain.len() + 16, 0);
        let ct = Aes256CbcEnc::new(key[..32].into(), &iv.into())
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
            .unwrap()
            .to_vec();
        let mut file = iv.to_vec();
        file.extend_from_slice(&ct);
        let mut h = <Hmac<Sha256> as Mac>::new_from_slice(&key[32..]).unwrap();
        h.update(&file);
        file.extend_from_slice(&h.finalize().into_bytes());
        let k = base64::engine::general_purpose::STANDARD.encode(&key);
        assert_eq!(decrypt_attachment(&file, &k, 16).unwrap(), b"hello attachment");
        let mut bad = file.clone();
        bad[20] ^= 1;
        assert!(decrypt_attachment(&bad, &k, 0).is_err());
    }

    #[test]
    fn safe_storage_v10() {
        let pw = b"secret";
        let mut key = [0u8; 16];
        pbkdf2::pbkdf2_hmac::<sha1::Sha1>(pw, b"saltysalt", 1003, &mut key);
        let plain = b"00ff";
        let mut buf = plain.to_vec();
        buf.resize(32, 0);
        let ct = Aes128CbcEnc::new(&key.into(), &[b' '; 16].into())
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
            .unwrap()
            .to_vec();
        let mut v = b"v10".to_vec();
        v.extend_from_slice(&ct);
        assert_eq!(safe_storage_decrypt(&hex::encode(v), pw).unwrap(), "00ff");
    }
}
