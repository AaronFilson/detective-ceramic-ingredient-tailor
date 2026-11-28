# frozen_string_literal: true

require "rqrcode"

module Media
  # Generates compact standalone inline <svg> QR codes for printable studio
  # test-tile worksheets and kiln firing bench sheets.
  class QrSvgGenerator
    def self.call(url, module_size: 3)
      new(url, module_size: module_size).call
    end

    def initialize(url, module_size: 3)
      @url = url.to_s.strip
      @module_size = module_size.to_i.clamp(1, 20)
    end

    def call
      return "".html_safe if @url.blank?

      svg = RQRCode::QRCode.new(@url).as_svg(
        module_size: @module_size,
        standalone: true,
        use_path: true,
        viewbox: true
      )
      svg.sub(/\A<\?xml[^>]*\?>\s*/, "").html_safe
    rescue StandardError => e
      Rails.logger.warn("[Media::QrSvgGenerator] QR SVG generation failed (#{e.class}): #{e.message}")
      "".html_safe
    end
  end
end
