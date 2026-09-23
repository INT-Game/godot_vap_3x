extends Resource

# MP4Decoder is a native library and can only open a real filesystem path.
# Keep the original bytes in the imported resource so exported PCK builds can
# materialize the video under user:// before passing it to the decoder.
export(PoolByteArray) var data = PoolByteArray()
export(String) var source_md5 = ""
