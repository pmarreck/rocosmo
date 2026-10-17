//! The descriptor the `--windows-launcher` front PE carries: one definition
//! shared by the packer (which locates the magic and fills the fields once the
//! container's layout is known) and the launcher (which reads them at run time
//! to find the index and the app payload entry to rebuild and run).
//! Fixed byte layout, little-endian; the two name fields are NUL-padded.

pub const magic = "ROCOSMO-LAUNCH01".*; // 16 bytes; the packer searches for this
pub const name_max = 32; // target entry name
pub const id_max = 64; // app id

pub const off_index_offset = 16; // u64: byte offset of the index in the container
pub const off_index_len = 24; // u64: index length
pub const off_target = 32; // [name_max] NUL-padded entry name to rebuild
pub const off_hash = off_target + name_max; // 64: [16] cache hash (hex) of that entry
pub const off_app_id = off_hash + 16; // 80: [id_max] NUL-padded app id
pub const size = off_app_id + id_max; // 144
