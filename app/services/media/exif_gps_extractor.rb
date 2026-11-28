# frozen_string_literal: true

module Media
  # Pure-Ruby, zero-dependency EXIF GPS extractor for JPEG photographs.
  # Parses SOI (0xFFD8) -> APP1 (0xFFE1) Exif\0\0 -> TIFF (II/MM) ->
  # IFD0 GPSInfo pointer (0x8825) -> GPS IFD latitude/longitude DMS rationals.
  # Never raises; always rewinds IO inputs and returns nil on non-JPEG or invalid data.
  class ExifGpsExtractor
    MAX_SCAN_BYTES = 2 * 1024 * 1024
    JPEG_SOI_FIRST = 0xFF
    JPEG_SOI_SECOND = 0xD8
    MARKER_APP1 = 0xE1
    MARKER_SOS = 0xDA
    MARKER_EOI = 0xD9
    STANDALONE_MARKERS = [ 0x01, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8 ].freeze

    EXIF_HEADER = "Exif\x00\x00".b
    TIFF_MAGIC = 42
    TAG_GPS_IFD_POINTER = 0x8825
    TAG_GPS_LATITUDE_REF = 0x0001
    TAG_GPS_LATITUDE = 0x0002
    TAG_GPS_LONGITUDE_REF = 0x0003
    TAG_GPS_LONGITUDE = 0x0004
    MAX_IFD_ENTRIES = 512

    def self.extract(input)
      new(input).extract
    rescue StandardError
      nil
    end

    def initialize(input)
      @input = input
    end

    def extract
      bytes = read_bytes(@input)
      return nil if bytes.nil? || bytes.bytesize < 12
      return nil unless jpeg?(bytes)

      each_app1_exif_tiff(bytes) do |tiff|
        coords = parse_tiff_gps(tiff)
        return coords if coords
      end

      nil
    rescue StandardError
      nil
    end

    private

    def read_bytes(input)
      return nil if input.nil?

      if input.is_a?(String)
        if jpeg?(input)
          return input.b.byteslice(0, MAX_SCAN_BYTES)
        end

        if !input.include?("\x00") && input.bytesize < 4096 && File.file?(input)
          return File.binread(input, MAX_SCAN_BYTES)
        end

        return input.b.byteslice(0, MAX_SCAN_BYTES)
      end

      if defined?(Pathname) && input.is_a?(Pathname)
        return input.file? ? File.binread(input.to_s, MAX_SCAN_BYTES) : nil
      end

      io = resolve_io(input)
      return nil unless io

      io.rewind if io.respond_to?(:rewind)
      data = io.read(MAX_SCAN_BYTES)
      data&.b
    ensure
      io.rewind if defined?(io) && io.respond_to?(:rewind)
      input.rewind if input.respond_to?(:rewind) && input != io
    end

    def resolve_io(input)
      if input.respond_to?(:tempfile) && input.tempfile.respond_to?(:read)
        input.tempfile
      elsif input.respond_to?(:read)
        input
      end
    end

    def jpeg?(bytes)
      bytes.bytesize >= 2 &&
        bytes.getbyte(0) == JPEG_SOI_FIRST &&
        bytes.getbyte(1) == JPEG_SOI_SECOND
    end

    def each_app1_exif_tiff(bytes)
      offset = 2
      total = bytes.bytesize

      while offset + 2 <= total
        break unless bytes.getbyte(offset) == 0xFF

        offset += 1 while offset < total && bytes.getbyte(offset) == 0xFF
        break if offset >= total

        marker = bytes.getbyte(offset)
        offset += 1

        break if marker == MARKER_SOS || marker == MARKER_EOI
        next if STANDALONE_MARKERS.include?(marker)

        break if offset + 2 > total

        seg_len = bytes.byteslice(offset, 2).unpack1("n")
        break if seg_len < 2 || offset + seg_len > total

        if marker == MARKER_APP1 && seg_len >= 8
          payload = bytes.byteslice(offset + 2, seg_len - 2)
          if payload.start_with?(EXIF_HEADER)
            tiff = payload.byteslice(EXIF_HEADER.bytesize, payload.bytesize - EXIF_HEADER.bytesize)
            yield tiff if tiff && tiff.bytesize >= 8
          end
        end

        offset += seg_len
      end
    end

    def parse_tiff_gps(tiff)
      return nil if tiff.bytesize < 8

      endian = case tiff.byteslice(0, 2)
      when "II".b then :little
      when "MM".b then :big
      else return nil
      end

      return nil unless unpack_u16(tiff, 2, endian) == TIFF_MAGIC

      ifd0_offset = unpack_u32(tiff, 4, endian)
      gps_ifd_offset = find_gps_ifd_offset(tiff, ifd0_offset, endian)
      return nil unless gps_ifd_offset

      parse_gps_ifd(tiff, gps_ifd_offset, endian)
    end

    def find_gps_ifd_offset(tiff, ifd_offset, endian)
      return nil if ifd_offset.nil? || ifd_offset < 8 || ifd_offset + 2 > tiff.bytesize

      entry_count = unpack_u16(tiff, ifd_offset, endian)
      return nil if entry_count.nil? || entry_count.zero? || entry_count > MAX_IFD_ENTRIES

      entry_count.times do |idx|
        entry_pos = ifd_offset + 2 + (idx * 12)
        break if entry_pos + 12 > tiff.bytesize

        tag = unpack_u16(tiff, entry_pos, endian)
        next unless tag == TAG_GPS_IFD_POINTER

        return unpack_u32(tiff, entry_pos + 8, endian)
      end

      nil
    end

    def parse_gps_ifd(tiff, gps_offset, endian)
      return nil if gps_offset < 8 || gps_offset + 2 > tiff.bytesize

      entry_count = unpack_u16(tiff, gps_offset, endian)
      return nil if entry_count.nil? || entry_count.zero? || entry_count > MAX_IFD_ENTRIES

      lat_ref = nil
      lat_dms = nil
      lng_ref = nil
      lng_dms = nil

      entry_count.times do |idx|
        entry_pos = gps_offset + 2 + (idx * 12)
        break if entry_pos + 12 > tiff.bytesize

        tag = unpack_u16(tiff, entry_pos, endian)
        type = unpack_u16(tiff, entry_pos + 2, endian)
        count = unpack_u32(tiff, entry_pos + 4, endian)

        case tag
        when TAG_GPS_LATITUDE_REF
          lat_ref = read_ascii_ref(tiff, entry_pos, count, endian)
        when TAG_GPS_LATITUDE
          lat_dms = read_dms_rationals(tiff, entry_pos, type, count, endian)
        when TAG_GPS_LONGITUDE_REF
          lng_ref = read_ascii_ref(tiff, entry_pos, count, endian)
        when TAG_GPS_LONGITUDE
          lng_dms = read_dms_rationals(tiff, entry_pos, type, count, endian)
        end
      end

      build_coordinates(lat_dms, lat_ref, lng_dms, lng_ref)
    end

    def read_ascii_ref(tiff, entry_pos, count, endian)
      return nil if count.nil? || count.zero?

      raw = if count <= 4
        tiff.byteslice(entry_pos + 8, count)
      else
        value_offset = unpack_u32(tiff, entry_pos + 8, endian)
        return nil if value_offset.nil? || value_offset + count > tiff.bytesize

        tiff.byteslice(value_offset, count)
      end

      return nil unless raw

      cleaned = raw.delete("\x00").strip.upcase
      cleaned[0]
    end

    def read_dms_rationals(tiff, entry_pos, type, count, endian)
      return nil unless [ 5, 10 ].include?(type) && count == 3

      value_offset = unpack_u32(tiff, entry_pos + 8, endian)
      return nil if value_offset.nil? || value_offset + 24 > tiff.bytesize

      signed = (type == 10)
      3.times.map do |i|
        pos = value_offset + (i * 8)
        num = signed ? unpack_s32(tiff, pos, endian) : unpack_u32(tiff, pos, endian)
        den = signed ? unpack_s32(tiff, pos + 4, endian) : unpack_u32(tiff, pos + 4, endian)
        return nil if num.nil? || den.nil? || den.zero?

        num.to_f / den.to_f
      end
    end

    def build_coordinates(lat_dms, lat_ref, lng_dms, lng_ref)
      return nil unless lat_dms && lng_dms
      return nil unless %w[N S].include?(lat_ref) && %w[E W].include?(lng_ref)

      lat = dms_to_decimal(lat_dms)
      lng = dms_to_decimal(lng_dms)
      return nil if lat.nil? || lng.nil?

      lat = -lat.abs if lat_ref == "S"
      lat = lat.abs if lat_ref == "N"
      lng = -lng.abs if lng_ref == "W"
      lng = lng.abs if lng_ref == "E"

      return nil if lat.nan? || lat.infinite? || lng.nan? || lng.infinite?
      return nil unless lat.between?(-90.0, 90.0) && lng.between?(-180.0, 180.0)

      { latitude: lat.round(6), longitude: lng.round(6) }
    end

    def dms_to_decimal(dms)
      deg, min, sec = dms
      return nil if deg.nan? || min.nan? || sec.nan?

      deg + (min / 60.0) + (sec / 3600.0)
    end

    def unpack_u16(data, offset, endian)
      slice = data.byteslice(offset, 2)
      return nil unless slice && slice.bytesize == 2

      slice.unpack1(endian == :little ? "v" : "n")
    end

    def unpack_u32(data, offset, endian)
      slice = data.byteslice(offset, 4)
      return nil unless slice && slice.bytesize == 4

      slice.unpack1(endian == :little ? "V" : "N")
    end

    def unpack_s32(data, offset, endian)
      slice = data.byteslice(offset, 4)
      return nil unless slice && slice.bytesize == 4

      slice.unpack1(endian == :little ? "l<" : "l>")
    end
  end
end
