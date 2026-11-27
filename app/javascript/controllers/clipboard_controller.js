import { Controller } from "@hotwired/stimulus"

// Copies fetched JSON export payloads (Glazecalc) or API URLs to clipboard with crisp feedback
export default class extends Controller {
  static targets = ["feedback"]

  disconnect() {
    if (this.feedbackTimer) {
      clearTimeout(this.feedbackTimer)
    }
  }

  async copyFromUrl(event) {
    const button = event.currentTarget
    const url = event.params.url
    const defaultLabel = event.params.defaultLabel || button.textContent.trim()
    if (!url) return

    button.disabled = true
    button.textContent = "Fetching JSON…"

    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" }
      })

      if (!response.ok) {
        throw new Error(`Export endpoint returned HTTP ${response.status}`)
      }

      const rawText = await response.text()
      let formatted = rawText
      try {
        formatted = JSON.stringify(JSON.parse(rawText), null, 2)
      } catch (_parseErr) {
        // Keep raw body if already formatted
      }

      await this.writeClipboard(formatted)
      this.flashSuccess(button, defaultLabel, "Copied!", "Glazecalc JSON copied to clipboard.")
    } catch (error) {
      this.flashError(button, defaultLabel, error.message || "Could not fetch export JSON.")
    } finally {
      button.disabled = false
    }
  }

  async copyText(event) {
    const button = event.currentTarget
    const rawText = event.params.text
    const defaultLabel = event.params.defaultLabel || button.textContent.trim()
    if (!rawText) return

    const valueToCopy = event.params.fullUrl
      ? new URL(rawText, window.location.origin).toString()
      : rawText

    try {
      await this.writeClipboard(valueToCopy)
      this.flashSuccess(button, defaultLabel, "Copied!", "API URL copied to clipboard.")
    } catch (_error) {
      this.flashError(button, defaultLabel, "Clipboard copy unavailable in this browser.")
    }
  }

  async writeClipboard(text) {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      await navigator.clipboard.writeText(text)
      return
    }

    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    document.execCommand("copy")
    document.body.removeChild(textarea)
  }

  flashSuccess(button, defaultLabel, temporaryLabel, statusMessage) {
    button.textContent = temporaryLabel

    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = statusMessage
      this.feedbackTarget.classList.remove("hidden", "text-red-700")
      this.feedbackTarget.classList.add("text-emerald-800")
    }

    this.scheduleReset(button, defaultLabel)
  }

  flashError(button, defaultLabel, errorMessage) {
    button.textContent = defaultLabel

    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = errorMessage
      this.feedbackTarget.classList.remove("hidden", "text-emerald-800")
      this.feedbackTarget.classList.add("text-red-700")
    }

    this.scheduleReset(button, defaultLabel)
  }

  scheduleReset(button, defaultLabel) {
    if (this.feedbackTimer) {
      clearTimeout(this.feedbackTimer)
    }

    this.feedbackTimer = setTimeout(() => {
      button.textContent = defaultLabel
      if (this.hasFeedbackTarget) {
        this.feedbackTarget.classList.add("hidden")
      }
    }, 2600)
  }
}
