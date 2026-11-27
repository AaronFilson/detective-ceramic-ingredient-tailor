import { Controller } from "@hotwired/stimulus"

// Interactive Leaflet geological map picker + Macrostrat carto overlay + Turbo Frame lookup
export default class extends Controller {
  static targets = [
    "canvas",
    "latInput",
    "lngInput",
    "geologicUnitIdInput",
    "geologicFrame",
    "macrostratToggle",
    "macrostratOpacity",
    "opacityReadout",
    "referenceToggle",
    "mineralToggle",
    "coordsDisplay"
  ]

  static values = {
    lat: { type: Number, default: 47.2529 },
    lng: { type: Number, default: -122.4443 },
    zoom: { type: Number, default: 8 },
    lookupUrl: { type: String, default: "/samples/geologic_lookup" },
    sampleId: { type: String, default: "" },
    macrostratOpacity: { type: Number, default: 0.65 },
    macrostratVisible: { type: Boolean, default: true },
    referenceAssays: { type: Array, default: [] },
    mineralOccurrences: { type: Array, default: [] },
    boundaryGeojson: { type: String, default: "" },
    boundaryColor: { type: String, default: "#1E4E79" },
    boundaryLabel: { type: String, default: "" }
  }

  connect() {
    if (!this.hasCanvasTarget || typeof window.L === "undefined") {
      return
    }

    this.initMap()
  }

  disconnect() {
    if (this.map) {
      this.map.remove()
      this.map = null
    }
    this.marker = null
    this.macrostratLayer = null
    this.referenceLayerGroup = null
    this.mineralLayerGroup = null
    this.boundaryLayer = null
  }

  initMap() {
    const L = window.L
    const initialLat = this.latValue || 47.2529
    const initialLng = this.lngValue || -122.4443

    this.map = L.map(this.canvasTarget, {
      center: [initialLat, initialLng],
      zoom: this.zoomValue || 8,
      zoomControl: false
    })

    L.control.zoom({ position: "bottomright" }).addTo(this.map)

    // Base OpenStreetMap layer
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors",
      maxZoom: 18
    }).addTo(this.map)

    // Macrostrat geologic map tile overlay
    const opacity = this.hasMacrostratOpacityTarget
      ? parseFloat(this.macrostratOpacityTarget.value)
      : this.macrostratOpacityValue

    this.macrostratLayer = L.tileLayer("https://tiles.macrostrat.org/carto/{z}/{x}/{y}.png", {
      attribution: "Geologic Map &copy; Macrostrat",
      opacity: Number.isFinite(opacity) ? opacity : 0.65,
      maxZoom: 16
    })

    const shouldShowMacrostrat = this.hasMacrostratToggleTarget
      ? this.macrostratToggleTarget.checked
      : this.macrostratVisibleValue

    if (shouldShowMacrostrat) {
      this.macrostratLayer.addTo(this.map)
    }

    // Reference assays layer
    this.referenceLayerGroup = L.layerGroup()
    this.renderReferenceAssays()
    if (!this.hasReferenceToggleTarget || this.referenceToggleTarget.checked) {
      this.referenceLayerGroup.addTo(this.map)
    }

    // Hard-rock mineral occurrences layer
    this.mineralLayerGroup = L.layerGroup()
    this.renderMineralOccurrences()
    if (!this.hasMineralToggleTarget || this.mineralToggleTarget.checked) {
      this.mineralLayerGroup.addTo(this.map)
    }

    // Active geologic unit GeoJSON boundary polygon
    if (this.boundaryGeojsonValue) {
      this.renderBoundaryPolygon(this.boundaryGeojsonValue, this.boundaryColorValue, this.boundaryLabelValue)
    }

    // Active sample pin (custom terracotta circle pin)
    this.placeMarker(initialLat, initialLng)

    // Map click drops/moves pin and reloads Macrostrat GeologicUnit Turbo Frame
    this.map.on("click", (event) => {
      this.selectPoint(event.latlng.lat, event.latlng.lng)
    })

    requestAnimationFrame(() => {
      if (this.map) {
        this.map.invalidateSize()
      }
    })
  }

  placeMarker(lat, lng) {
    const L = window.L
    if (!this.map || !L) return

    const pinIcon = L.divIcon({
      className: "studio-sample-pin",
      html: '<div class="studio-sample-pin__dot"></div>',
      iconSize: [22, 22],
      iconAnchor: [11, 11]
    })

    if (this.marker) {
      this.marker.setLatLng([lat, lng])
    } else {
      this.marker = L.marker([lat, lng], {
        icon: pinIcon,
        draggable: true,
        zIndexOffset: 500
      }).addTo(this.map)

      this.marker.on("dragend", (event) => {
        const pos = event.target.getLatLng()
        this.selectPoint(pos.lat, pos.lng)
      })
    }
  }

  selectPoint(lat, lng, options = {}) {
    const cleanLat = Number(lat)
    const cleanLng = Number(lng)
    if (!Number.isFinite(cleanLat) || !Number.isFinite(cleanLng)) return

    const boundedLat = Math.max(-90, Math.min(90, cleanLat))
    const boundedLng = Math.max(-180, Math.min(180, cleanLng))

    this.latValue = boundedLat
    this.lngValue = boundedLng

    this.placeMarker(boundedLat, boundedLng)

    if (options.pan && this.map) {
      const targetZoom = options.zoom || Math.max(this.map.getZoom(), 10)
      this.map.flyTo([boundedLat, boundedLng], targetZoom, { duration: 0.65 })
    }

    if (this.hasLatInputTarget) {
      this.latInputTarget.value = boundedLat.toFixed(5)
    }
    if (this.hasLngInputTarget) {
      this.lngInputTarget.value = boundedLng.toFixed(5)
    }
    if (this.hasCoordsDisplayTarget) {
      this.coordsDisplayTarget.textContent = `${boundedLat.toFixed(4)}, ${boundedLng.toFixed(4)}`
    }
    if (this.hasGeologicUnitIdInputTarget) {
      this.geologicUnitIdInputTarget.value = ""
    }

    this.reloadGeologicUnitFrame(boundedLat, boundedLng)
  }

  reloadGeologicUnitFrame(lat, lng) {
    if (!this.hasGeologicFrameTarget) return

    const url = new URL(this.lookupUrlValue, window.location.origin)
    url.searchParams.set("lat", lat.toFixed(5))
    url.searchParams.set("lng", lng.toFixed(5))
    if (this.sampleIdValue) {
      url.searchParams.set("sample_id", this.sampleIdValue)
    }

    const nextSrc = url.toString()
    if (this.geologicFrameTarget.src === nextSrc && typeof this.geologicFrameTarget.reload === "function") {
      this.geologicFrameTarget.reload()
    } else {
      this.geologicFrameTarget.src = nextSrc
    }
  }

  // Triggered by quick PNW preset location buttons
  jumpToLocation(event) {
    const lat = parseFloat(event.params.lat)
    const lng = parseFloat(event.params.lng)
    const zoom = parseInt(event.params.zoom, 10) || 10
    this.selectPoint(lat, lng, { pan: true, zoom })
  }

  // Triggered when user manually edits lat/lng numeric fields
  syncFromInputs() {
    if (!this.hasLatInputTarget || !this.hasLngInputTarget) return

    const lat = parseFloat(this.latInputTarget.value)
    const lng = parseFloat(this.lngInputTarget.value)
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      this.selectPoint(lat, lng, { pan: true })
    }
  }

  toggleMacrostrat() {
    if (!this.map || !this.macrostratLayer || !this.hasMacrostratToggleTarget) return

    if (this.macrostratToggleTarget.checked) {
      this.macrostratLayer.addTo(this.map)
    } else {
      this.map.removeLayer(this.macrostratLayer)
    }
  }

  updateMacrostratOpacity(event) {
    const opacity = parseFloat(event.target.value)
    if (!Number.isFinite(opacity)) return

    if (this.macrostratLayer) {
      this.macrostratLayer.setOpacity(opacity)
    }
    if (this.hasOpacityReadoutTarget) {
      this.opacityReadoutTarget.textContent = `${Math.round(opacity * 100)}%`
    }
  }

  toggleReferenceAssays() {
    if (!this.map || !this.referenceLayerGroup || !this.hasReferenceToggleTarget) return

    if (this.referenceToggleTarget.checked) {
      this.referenceLayerGroup.addTo(this.map)
    } else {
      this.map.removeLayer(this.referenceLayerGroup)
    }
  }

  toggleMineralOccurrences() {
    if (!this.map || !this.mineralLayerGroup || !this.hasMineralToggleTarget) return

    if (this.mineralToggleTarget.checked) {
      this.mineralLayerGroup.addTo(this.map)
    } else {
      this.map.removeLayer(this.mineralLayerGroup)
    }
  }

  // Called on turbo:frame-load of #geologic_unit_card
  handleGeologicUnitLoaded() {
    if (!this.hasGeologicFrameTarget) return

    const meta = this.geologicFrameTarget.querySelector("[data-geologic-unit-meta]")
    if (!meta) return

    if (this.hasGeologicUnitIdInputTarget) {
      this.geologicUnitIdInputTarget.value = meta.dataset.geologicUnitId || ""
    }

    const boundaryJson = meta.dataset.boundaryGeojson || ""
    const color = meta.dataset.unitColor || "#1E4E79"
    const unitName = meta.dataset.unitName || ""
    this.renderBoundaryPolygon(boundaryJson, color, unitName)
  }

  renderReferenceAssays() {
    const L = window.L
    if (!this.referenceLayerGroup || !L) return

    this.referenceLayerGroup.clearLayers()

    this.referenceAssaysValue.forEach((assay) => {
      if (assay.lat == null || assay.lng == null) return

      const rockLabel = this.formatRockType(assay.rock_type)
      const oxides = assay.oxides || {}

      const popupHtml = `
        <div class="text-xs space-y-1.5 min-w-[180px]">
          <div class="font-bold text-stone-900">${this.escapeHtml(rockLabel)}</div>
          ${assay.locality ? `<div class="text-[11px] text-stone-600">${this.escapeHtml(assay.locality)}</div>` : ""}
          ${assay.formation ? `<div class="text-[10px] text-stone-500">${this.escapeHtml(assay.formation)}</div>` : ""}
          <div class="grid grid-cols-3 gap-1.5 pt-1 border-t border-stone-200 font-mono text-[11px]">
            <div><span class="text-stone-500">SiO2</span><br><strong>${this.fmtPct(oxides.SiO2)}</strong></div>
            <div><span class="text-stone-500">Al2O3</span><br><strong>${this.fmtPct(oxides.Al2O3)}</strong></div>
            <div><span class="text-stone-500">Fe2O3</span><br><strong>${this.fmtPct(oxides.Fe2O3)}</strong></div>
          </div>
        </div>
      `

      L.circleMarker([assay.lat, assay.lng], {
        radius: 5.5,
        color: "#FCFBF8",
        weight: 1.5,
        fillColor: "#1E4E79",
        fillOpacity: 0.78
      })
        .bindPopup(popupHtml)
        .addTo(this.referenceLayerGroup)
    })
  }

  renderMineralOccurrences() {
    const L = window.L
    if (!this.mineralLayerGroup || !L) return

    this.mineralLayerGroup.clearLayers()

    const diamondIcon = L.divIcon({
      className: "studio-mineral-marker",
      html: '<div style="width:12px;height:12px;background:#D97706;border:2px solid #FCFBF8;transform:rotate(45deg);box-shadow:0 1px 4px rgba(28,25,23,0.45);border-radius:2px;"></div>',
      iconSize: [14, 14],
      iconAnchor: [7, 7],
      popupAnchor: [0, -8]
    })

    this.mineralOccurrencesValue.forEach((occ) => {
      if (occ.lat == null || occ.lng == null) return

      const sourceLabel = this.formatMineralSource(occ.source)
      const commodities = Array.isArray(occ.commodities) ? occ.commodities.filter(Boolean) : []
      const ceramicMinerals = Array.isArray(occ.ceramic_highlights) && occ.ceramic_highlights.length > 0
        ? occ.ceramic_highlights
        : (Array.isArray(occ.minerals) ? occ.minerals.filter(Boolean) : [])

      const popupHtml = `
        <div class="text-xs space-y-1.5 min-w-[200px]">
          <div class="flex items-start justify-between gap-2">
            <div class="font-bold text-stone-900 leading-snug">${this.escapeHtml(occ.name || "Mineral Occurrence")}</div>
            <span class="shrink-0 px-1.5 py-0.5 rounded bg-amber-100 text-amber-900 border border-amber-300 font-mono text-[9px] font-bold uppercase">${this.escapeHtml(sourceLabel)}</span>
          </div>
          ${occ.deposit_type ? `<div class="text-[11px] text-stone-600"><span class="font-medium text-stone-500">Type:</span> ${this.escapeHtml(occ.deposit_type)}</div>` : ""}
          ${commodities.length > 0 ? `<div class="text-[11px] text-stone-700"><span class="font-medium text-stone-500">Commodities:</span> ${this.escapeHtml(commodities.join(", "))}</div>` : ""}
          ${ceramicMinerals.length > 0 ? `<div class="pt-1 border-t border-stone-200 flex flex-wrap gap-1">${ceramicMinerals.slice(0, 6).map((m) => `<span class="px-1.5 py-0.5 rounded bg-amber-50 text-amber-950 border border-amber-200 text-[10px] font-medium">${this.escapeHtml(m)}</span>`).join("")}</div>` : ""}
        </div>
      `

      L.marker([occ.lat, occ.lng], {
        icon: diamondIcon,
        zIndexOffset: 200
      })
        .bindPopup(popupHtml)
        .addTo(this.mineralLayerGroup)
    })
  }

  formatMineralSource(source) {
    switch (String(source || "").toLowerCase()) {
      case "usgs_mrds": return "USGS MRDS"
      case "mindat": return "Mindat"
      case "pnw_seed":
      case "curated_pnw": return "PNW Atlas"
      default: return source ? String(source).replace(/_/g, " ") : "Mineral"
    }
  }

  renderBoundaryPolygon(geojsonString, color, label) {
    const L = window.L
    if (!this.map || !L) return

    if (this.boundaryLayer) {
      this.map.removeLayer(this.boundaryLayer)
      this.boundaryLayer = null
    }

    if (!geojsonString) return

    try {
      const parsed = typeof geojsonString === "string" ? JSON.parse(geojsonString) : geojsonString
      const strokeColor = color || "#1E4E79"

      this.boundaryLayer = L.geoJSON(parsed, {
        style: {
          color: strokeColor,
          weight: 2.5,
          opacity: 0.9,
          fillColor: strokeColor,
          fillOpacity: 0.22
        }
      }).addTo(this.map)

      if (label) {
        this.boundaryLayer.bindTooltip(label, { sticky: true })
      }
    } catch (_err) {
      // Ignore malformed boundary GeoJSON cleanly
    }
  }

  // Topbar saved sample switcher
  navigateSample(event) {
    const targetUrl = event.target.value
    if (!targetUrl) return

    if (window.Turbo && typeof window.Turbo.visit === "function") {
      window.Turbo.visit(targetUrl)
    } else {
      window.location.assign(targetUrl)
    }
  }

  // Step 2 quick color swatch picker
  pickSwatch(event) {
    const targetId = event.params.targetId
    const value = event.params.value
    if (!targetId) return

    const input = document.getElementById(targetId)
    if (input) {
      input.value = value
      input.focus()
    }
  }

  formatRockType(str) {
    if (!str) return "Reference Assay"
    return String(str)
      .replace(/_/g, " ")
      .replace(/\b\w/g, (ch) => ch.toUpperCase())
  }

  fmtPct(val) {
    const num = Number(val)
    return Number.isFinite(num) ? `${num.toFixed(1)}%` : "—"
  }

  escapeHtml(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}
