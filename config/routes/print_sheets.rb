# frozen_string_literal: true

get "/samples/:id/print", to: "print_sheets#sample", as: :print_sample_sheet
get "/blends/print", to: "print_sheets#blend", as: :print_blend_sheet
