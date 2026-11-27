import { Controller } from "@hotwired/stimulus"

// Multi-step interactive first-time walkthrough & studio setup wizard for DCI Tailor
export default class extends Controller {
  static targets = [
    "stepPanel",
    "stepButton",
    "progressBar",
    "stepCounter",
    "prevButton",
    "nextButton",
    "submitButton",
    "regionButton",
    "regionLabelInput",
    "latInput",
    "lngInput",
    "zoomInput",
    "geoStatus"
  ]

  static values = {
    step: { type: Number, default: 1 },
    totalSteps: { type: Number, default: 4 }
  }

  connect() {
    this.renderStep()
  }

  stepValueChanged() {
    this.renderStep()
  }

  next() {
    if (this.stepValue < this.totalStepsValue) {
      this.stepValue += 1
    }
  }

  prev() {
    if (this.stepValue > 1) {
      this.stepValue -= 1
    }
  }

  goToStep(event) {
    const targetStep = Number(event.params.step)
    if (Number.isInteger(targetStep) && targetStep >= 1 && targetStep <= this.totalStepsValue) {
      this.stepValue = targetStep
    }
  }

  pickRegion(event) {
    const { label, lat, lng, zoom } = event.params
    if (this.hasRegionLabelInputTarget && label) this.regionLabelInputTarget.value = label
    if (this.hasLatInputTarget && lat !== undefined) this.latInputTarget.value = Number(lat).toFixed(4)
    if (this.hasLngInputTarget && lng !== undefined) this.lngInputTarget.value = Number(lng).toFixed(4)
    if (this.hasZoomInputTarget && zoom !== undefined) this.zoomInputTarget.value = Number(zoom)

    this.regionButtonTargets.forEach((btn) => {
      const selected = btn === event.currentTarget
      btn.classList.toggle("border-[#B84A27]", selected)
      btn.classList.toggle("bg-[#B84A27]/10", selected)
      btn.classList.toggle("ring-2", selected)
      btn.classList.toggle("ring-[#B84A27]/25", selected)
      btn.classList.toggle("border-[#D6C7B2]", !selected)
      btn.classList.toggle("bg-white", !selected)
    })

    if (this.hasGeoStatusTarget) {
      this.geoStatusTarget.textContent = `Selected ${label} (${Number(lat).toFixed(2)}, ${Number(lng).toFixed(2)})`
    }
  }

  detectLocation() {
    if (!navigator.geolocation) {
      if (this.hasGeoStatusTarget) {
        this.geoStatusTarget.textContent = "Browser geolocation is unavailable — enter coordinates manually."
      }
      return
    }

    if (this.hasGeoStatusTarget) {
      this.geoStatusTarget.textContent = "Detecting coordinates…"
    }

    navigator.geolocation.getCurrentPosition(
      (position) => {
        const lat = position.coords.latitude.toFixed(4)
        const lng = position.coords.longitude.toFixed(4)
        if (this.hasLatInputTarget) this.latInputTarget.value = lat
        if (this.hasLngInputTarget) this.lngInputTarget.value = lng
        if (this.hasZoomInputTarget) this.zoomInputTarget.value = 9
        if (this.hasRegionLabelInputTarget) this.regionLabelInputTarget.value = "My Studio Area"
        if (this.hasGeoStatusTarget) {
          this.geoStatusTarget.textContent = `Located studio at ${lat}, ${lng}`
        }
      },
      () => {
        if (this.hasGeoStatusTarget) {
          this.geoStatusTarget.textContent = "Location permission declined — choose a region preset or enter coordinates."
        }
      },
      { timeout: 8000 }
    )
  }

  renderStep() {
    const current = Math.min(Math.max(this.stepValue || 1, 1), this.totalStepsValue)

    this.stepPanelTargets.forEach((panel) => {
      const panelStep = Number(panel.dataset.step)
      panel.classList.toggle("hidden", panelStep !== current)
    })

    this.stepButtonTargets.forEach((btn) => {
      const btnStep = Number(btn.dataset.step)
      const isActive = btnStep === current
      const isComplete = btnStep < current

      btn.setAttribute("aria-current", isActive ? "step" : "false")
      btn.classList.toggle("bg-[#B84A27]", isActive)
      btn.classList.toggle("text-white", isActive)
      btn.classList.toggle("border-[#B84A27]", isActive)
      btn.classList.toggle("bg-emerald-50", isComplete && !isActive)
      btn.classList.toggle("text-emerald-900", isComplete && !isActive)
      btn.classList.toggle("border-emerald-200", isComplete && !isActive)
      btn.classList.toggle("bg-[#FAF7F2]", !isActive && !isComplete)
      btn.classList.toggle("text-stone-600", !isActive && !isComplete)
      btn.classList.toggle("border-[#D6C7B2]", !isActive && !isComplete)
    })

    if (this.hasProgressBarTarget) {
      const pct = Math.round((current / this.totalStepsValue) * 100)
      this.progressBarTarget.style.width = `${pct}%`
    }

    if (this.hasStepCounterTarget) {
      this.stepCounterTarget.textContent = `Step ${current} of ${this.totalStepsValue}`
    }

    if (this.hasPrevButtonTarget) {
      this.prevButtonTarget.classList.toggle("invisible", current <= 1)
    }

    if (this.hasNextButtonTarget) {
      this.nextButtonTarget.classList.toggle("hidden", current >= this.totalStepsValue)
    }

    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.classList.toggle("hidden", current < this.totalStepsValue)
    }
  }
}
