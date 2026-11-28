import { Controller } from "@hotwired/stimulus"

const ZONE_BADGE_CLASSES = {
  "Gloss": ["bg-[#1E4E79]/12", "text-[#1E4E79]", "border-[#1E4E79]/25"],
  "Matte": ["bg-emerald-900/10", "text-emerald-900", "border-emerald-800/25"],
  "Crazing / High-Silica": ["bg-amber-100", "text-amber-950", "border-amber-300"],
  "Unfused / Refractory": ["bg-stone-200", "text-stone-800", "border-stone-300"],
  "Underfired / High-Flux": ["bg-orange-100", "text-[#963B1D]", "border-orange-300"]
}

const ALL_ZONE_BADGE_TOKENS = Object.values(ZONE_BADGE_CLASSES).flat()

// Interactive inspector controller for 231-point SVG triaxial simplex heatmaps
// and 11-step ceramic line-blend melt strips.
export default class extends Controller {
  static targets = ["batch", "umf", "coe", "zone", "fit", "optimalBadge", "activeRing"]

  selectCandidate(event) {
    const el = event.currentTarget
    if (!el) return

    this.applyCandidateFromElement(el)
  }

  handleKeydown(event) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      this.selectCandidate(event)
    }
  }

  resetOptimal() {
    const optimalEl = this.element.querySelector(
      "[data-simplex-optimal='true'], [data-line-tile][data-optimal='true']"
    )
    if (optimalEl) {
      this.applyCandidateFromElement(optimalEl)
    }
  }

  applyCandidateFromElement(el) {
    const data = el.dataset

    if (this.hasBatchTarget && data.batch) {
      this.batchTarget.textContent = data.batch
    }

    if (this.hasUmfTarget) {
      const parts = [
        `SiO₂ ${data.sio2 || "—"}`,
        `Al₂O₃ ${data.al2o3 || "—"}`,
        `Si:Al ${data.siAl || "—"}`,
        `R₂O ${data.r2o || "—"}`,
        `RO ${data.ro || "—"}`
      ]
      const b2o3Val = parseFloat(data.b2o3 || "0")
      if (!Number.isNaN(b2o3Val) && b2o3Val > 0) {
        parts.push(`B₂O₃ ${data.b2o3}`)
      }
      this.umfTarget.textContent = parts.join(" · ")
    }

    if (this.hasCoeTarget) {
      if (data.coe && data.coe !== "—") {
        const riskSuffix = data.coeRisk ? ` (${data.coeRisk})` : ""
        this.coeTarget.textContent = `${data.coe} ×10⁻⁷ /°C${riskSuffix}`
      } else {
        this.coeTarget.textContent = "—"
      }
    }

    if (this.hasZoneTarget && data.zone) {
      this.zoneTarget.textContent = data.zone
      this.zoneTarget.classList.remove(...ALL_ZONE_BADGE_TOKENS)
      const tokens = ZONE_BADGE_CLASSES[data.zone] || ZONE_BADGE_CLASSES["Unfused / Refractory"]
      this.zoneTarget.classList.add(...tokens)
    }

    if (this.hasFitTarget && data.fit) {
      this.fitTarget.textContent = data.fit.includes("Fit") ? data.fit : `${data.fit} Fit`
    }

    if (this.hasOptimalBadgeTarget) {
      const isOptimal = data.optimal === "true"
      this.optimalBadgeTarget.classList.toggle("hidden", !isOptimal)
    }

    this.highlightActiveElement(el)
  }

  highlightActiveElement(el) {
    if (el.hasAttribute("data-simplex-point")) {
      const cx = el.getAttribute("cx")
      const cy = el.getAttribute("cy")
      if (this.hasActiveRingTarget && cx && cy) {
        this.activeRingTarget.setAttribute("cx", cx)
        this.activeRingTarget.setAttribute("cy", cy)
      }

      this.element.querySelectorAll("[data-simplex-point][data-selected='true']").forEach((node) => {
        node.removeAttribute("data-selected")
      })
      el.setAttribute("data-selected", "true")
    }

    if (el.hasAttribute("data-line-tile")) {
      this.element.querySelectorAll("[data-line-tile]").forEach((tile) => {
        const active = tile === el
        tile.setAttribute("aria-pressed", active ? "true" : "false")
        tile.classList.toggle("ring-2", active)
        tile.classList.toggle("ring-[#B84A27]", active)
        tile.classList.toggle("ring-offset-1", active)
      })
    }
  }
}
