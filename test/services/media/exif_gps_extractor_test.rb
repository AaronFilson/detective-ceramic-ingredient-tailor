# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Media::ExifGpsExtractorTest < ActiveSupport::TestCase
  # Pure-Ruby JPEG EXIF GPS binary fixture generator supporting both
  # little-endian ("II") and big-endian ("MM") TIFF headers.
  def build_jpeg_with_gps(lat:, lng:, endian: :little, include_app0: false)
    u16 = endian == :little ? "v" : "n"
    u32 = endian == :little ? "V" : "N"

    lat_ref = lat >= 0 ? "N\x00\x00\x00".b : "S\x00\x00\x00".b
    lng_ref = lng >= 0 ? "E\x00\x00\x00".b : "W\x00\x00\x00".b
    lat_dms = decimal_to_dms_rationals(lat.abs)
    lng_dms = decimal_to_dms_rationals(lng.abs)

    # TIFF layout:
    # 0..7   : TIFF header ("II" or "MM", magic 42, IFD0 offset = 8)
    # 8..25  : IFD0 (1 entry: tag 0x8825 GPSInfo pointer -> offset 26; next IFD = 0)
    # 26..79 : GPS IFD (4 entries: LatRef, Lat, LngRef, Lng; next IFD = 0)
    # 80..103: GPSLatitude 3 RATIONALs (24 bytes)
    # 104..127: GPSLongitude 3 RATIONALs (24 bytes)
    tiff = +"".b
    tiff << (endian == :little ? "II".b : "MM".b)
    tiff << [ 42 ].pack(u16)
    tiff << [ 8 ].pack(u32)

    # IFD0 at offset 8: 1 entry (12 bytes) + 4-byte next IFD offset = 18 bytes -> offset 26
    tiff << [ 1 ].pack(u16)
    tiff << [ 0x8825, 4, 1, 26 ].pack("#{u16}#{u16}#{u32}#{u32}")
    tiff << [ 0 ].pack(u32)

    # GPS IFD at offset 26: 2 + 4*12 + 4 = 54 bytes -> data starts at offset 80
    tiff << [ 4 ].pack(u16)
    # Tag 0x0001 GPSLatitudeRef (ASCII, count 2, inline)
    tiff << [ 0x0001, 2, 2 ].pack("#{u16}#{u16}#{u32}") << lat_ref
    # Tag 0x0002 GPSLatitude (RATIONAL, count 3, offset 80)
    tiff << [ 0x0002, 5, 3, 80 ].pack("#{u16}#{u16}#{u32}#{u32}")
    # Tag 0x0003 GPSLongitudeRef (ASCII, count 2, inline)
    tiff << [ 0x0003, 2, 2 ].pack("#{u16}#{u16}#{u32}") << lng_ref
    # Tag 0x0004 GPSLongitude (RATIONAL, count 3, offset 104)
    tiff << [ 0x0004, 5, 3, 104 ].pack("#{u16}#{u16}#{u32}#{u32}")
    tiff << [ 0 ].pack(u32)

    # Rational arrays
    lat_dms.each { |num, den| tiff << [ num, den ].pack("#{u32}#{u32}") }
    lng_dms.each { |num, den| tiff << [ num, den ].pack("#{u32}#{u32}") }

    app1_payload = "Exif\x00\x00".b + tiff
    app1_segment = "\xFF\xE1".b + [ app1_payload.bytesize + 2 ].pack("n") + app1_payload

    jpeg = +"\xFF\xD8".b
    if include_app0
      jfif_payload = "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".b
      jpeg << "\xFF\xE0".b << [ jfif_payload.bytesize + 2 ].pack("n") << jfif_payload
    end
    jpeg << app1_segment
    jpeg << "\xFF\xD9".b
    jpeg
  end

  def decimal_to_dms_rationals(decimal)
    deg = decimal.floor
    rem_min = (decimal - deg) * 60.0
    min = rem_min.floor
    sec = ((rem_min - min) * 60.0 * 10_000).round
    [ [ deg, 1 ], [ min, 1 ], [ sec, 10_000 ] ]
  end

  test "extracts Tacoma WA coordinates from little-endian (II) JPEG EXIF GPS" do
    jpeg = build_jpeg_with_gps(lat: 47.2529, lng: -122.4443, endian: :little)

    coords = Media::ExifGpsExtractor.extract(jpeg)

    assert_not_nil coords
    assert_in_delta 47.2529, coords[:latitude], 0.0001
    assert_in_delta(-122.4443, coords[:longitude], 0.0001)
  end

  test "extracts Tacoma WA coordinates from big-endian (MM) JPEG EXIF GPS with preceding APP0 segment" do
    jpeg = build_jpeg_with_gps(lat: 47.2529, lng: -122.4443, endian: :big, include_app0: true)

    coords = Media::ExifGpsExtractor.extract(jpeg)

    assert_not_nil coords
    assert_in_delta 47.2529, coords[:latitude], 0.0001
    assert_in_delta(-122.4443, coords[:longitude], 0.0001)
  end

  test "extracts Southern and Eastern hemisphere Sydney coordinates in both little-endian and big-endian" do
    %i[little big].each do |endian|
      jpeg = build_jpeg_with_gps(lat: -33.8688, lng: 151.2093, endian: endian)
      coords = Media::ExifGpsExtractor.extract(jpeg)

      assert_not_nil coords, "Expected coordinates for #{endian}-endian Sydney fixture"
      assert_in_delta(-33.8688, coords[:latitude], 0.0001)
      assert_in_delta 151.2093, coords[:longitude], 0.0001
    end
  end

  test "supports StringIO, file path, and ActionDispatch::Http::UploadedFile and always rewinds IO" do
    jpeg = build_jpeg_with_gps(lat: 47.2529, lng: -122.4443, endian: :little)

    io = StringIO.new(jpeg)
    io.read(10) # advance cursor before calling extractor
    coords_io = Media::ExifGpsExtractor.extract(io)
    assert_in_delta 47.2529, coords_io[:latitude], 0.0001
    assert_equal 0, io.pos, "StringIO should be rewound to 0 after extraction"
    assert_equal jpeg.bytesize, io.read.bytesize

    Tempfile.create([ "outcrop", ".jpg" ], binmode: true) do |tmp|
      tmp.write(jpeg)
      tmp.rewind

      coords_path = Media::ExifGpsExtractor.extract(tmp.path)
      assert_in_delta 47.2529, coords_path[:latitude], 0.0001

      uploaded = ActionDispatch::Http::UploadedFile.new(
        tempfile: tmp,
        filename: "outcrop.jpg",
        type: "image/jpeg"
      )
      coords_upload = Media::ExifGpsExtractor.extract(uploaded)
      assert_in_delta 47.2529, coords_upload[:latitude], 0.0001
      assert_equal 0, tmp.pos, "UploadedFile tempfile should be rewound cleanly"
      assert_equal jpeg, uploaded.read
    end
  end

  test "returns nil for PNG bytes without EXIF" do
    png_bytes = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xDE".b

    assert_nil Media::ExifGpsExtractor.extract(png_bytes)
    assert_nil Media::ExifGpsExtractor.extract(StringIO.new(png_bytes))
  end

  test "returns nil safely on JPEG without GPS tags, truncated, corrupt, or nil inputs" do
    plain_jpeg = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9".b
    truncated_exif = "\xFF\xD8\xFF\xE1\x00\x20Exif\x00\x00II*\x00".b
    corrupt_bytes = "\x00\xFF\xDE\xAD\xBE\xEF".b

    assert_nil Media::ExifGpsExtractor.extract(plain_jpeg)
    assert_nil Media::ExifGpsExtractor.extract(truncated_exif)
    assert_nil Media::ExifGpsExtractor.extract(corrupt_bytes)
    assert_nil Media::ExifGpsExtractor.extract("")
    assert_nil Media::ExifGpsExtractor.extract(nil)
  end

  test "rejects out-of-range and Null-Island (0.0, 0.0) GPS coordinates cleanly" do
    bad_jpeg = build_jpeg_with_gps(lat: 95.5, lng: -122.4, endian: :little)
    null_island_jpeg = build_jpeg_with_gps(lat: 0.0, lng: 0.0, endian: :little)

    assert_nil Media::ExifGpsExtractor.extract(bad_jpeg)
    assert_nil Media::ExifGpsExtractor.extract(null_island_jpeg)
  end
end
