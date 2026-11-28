# frozen_string_literal: true

module PhotoVariantsHelper
  # Returns an EXIF-stripped display variant URL when enabled (default in production),
  # preserving raw EXIF GPS only inside the private server-side UserSample upload while
  # never exposing camera/GPS metadata in rendered gallery or tile images.
  # Returns nil when the attachment or blob is blank/unpersisted, and fails closed
  # in production if EXIF-stripped variant generation errors out.
  def stripped_photo_url(attachment, resize_to_limit: [ 1200, 1200 ], strip_variants: nil)
    return nil if attachment.blank?
    return nil if attachment.respond_to?(:attached?) && !attachment.attached?

    record_attachment = attachment.respond_to?(:attachment) ? attachment.attachment : attachment
    blob = record_attachment.respond_to?(:blob) ? record_attachment.blob : nil
    persisted = record_attachment.present? &&
      record_attachment.respond_to?(:persisted?) &&
      record_attachment.persisted? &&
      blob.present? &&
      blob.persisted?
    return nil unless persisted

    strip_enabled =
      if strip_variants.nil?
        ENV.fetch("STRIP_PHOTO_EXIF_VARIANTS", Rails.env.production?.to_s) == "true"
      else
        strip_variants
      end

    if strip_enabled && attachment.respond_to?(:variable?) && attachment.variable?
      url_for(attachment.variant(resize_to_limit: resize_to_limit, saver: { strip: true }))
    else
      url_for(attachment)
    end
  rescue LoadError, StandardError => e
    Rails.logger.warn("[PhotoVariantsHelper] Variant generation fallback (#{e.class}): #{e.message}")
    return nil if strip_enabled && Rails.env.production?

    begin
      url_for(attachment)
    rescue StandardError
      nil
    end
  end
end
