# frozen_string_literal: true

require "test_helper"
require "stringio"

class PhotoVariantsHelperTest < ActionView::TestCase
  MINIMAL_JPEG_BYTES = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9".b

  test "returns nil when attachment is nil or unattached" do
    sample = UserSample.new(title: "Unattached Sample", material_category: :wild_clay)
    obs = sample.field_observations.build

    assert_nil stripped_photo_url(nil)
    assert_nil stripped_photo_url(obs.raw_tile_photo)
  end

  test "returns EXIF-stripped representation URL when strip_variants is enabled" do
    sample = UserSample.create!(title: "Variant Sample", material_category: :wild_clay)
    sample.outcrop_photos.attach(
      io: StringIO.new(MINIMAL_JPEG_BYTES),
      filename: "outcrop_gps.jpg",
      content_type: "image/jpeg"
    )
    photo = sample.outcrop_photos.first

    variant = photo.variant(resize_to_limit: [ 800, 800 ], saver: { strip: true })
    assert_equal({ strip: true }, variant.variation.transformations[:saver])

    stripped_url = stripped_photo_url(photo, resize_to_limit: [ 800, 800 ], strip_variants: true)
    assert_includes stripped_url, "/rails/active_storage/representations/"

    raw_url = stripped_photo_url(photo, resize_to_limit: [ 800, 800 ], strip_variants: false)
    assert_includes raw_url, "/rails/active_storage/blobs/"
  end

  test "honors STRIP_PHOTO_EXIF_VARIANTS environment variable for attached one-to-one tile photos" do
    sample = UserSample.create!(title: "Tile Variant Sample", material_category: :wild_clay)
    obs = sample.field_observations.create!(vinegar_fizz: :none)
    obs.raw_tile_photo.attach(
      io: StringIO.new(MINIMAL_JPEG_BYTES),
      filename: "raw_tile.jpg",
      content_type: "image/jpeg"
    )

    original_env = ENV["STRIP_PHOTO_EXIF_VARIANTS"]
    ENV["STRIP_PHOTO_EXIF_VARIANTS"] = "true"
    assert_includes stripped_photo_url(obs.raw_tile_photo), "/rails/active_storage/representations/"
  ensure
    if original_env.nil?
      ENV.delete("STRIP_PHOTO_EXIF_VARIANTS")
    else
      ENV["STRIP_PHOTO_EXIF_VARIANTS"] = original_env
    end
  end

  test "falls back cleanly to blob url when variant generation raises LoadError or attachment is not variable" do
    sample = UserSample.create!(title: "Fallback Sample", material_category: :wild_clay)
    sample.outcrop_photos.attach(
      io: StringIO.new(MINIMAL_JPEG_BYTES),
      filename: "fallback.jpg",
      content_type: "image/jpeg"
    )
    photo = sample.outcrop_photos.first
    expected_blob_url = url_for(photo)

    photo.define_singleton_method(:variant) { |**_opts| raise LoadError, "vips missing" }
    assert_equal expected_blob_url, stripped_photo_url(photo, strip_variants: true)
  end
end
